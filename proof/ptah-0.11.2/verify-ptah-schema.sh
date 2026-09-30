#!/bin/sh
# 在 schema-test 镜像内运行，目标库和临时库必须独立且为空。
set -eu
: "${DATABASE_URL:?必须配置 DATABASE_URL}"
: "${DEV_URL:?必须配置 DEV_URL}"
: "${UPGRADE_DATABASE_URL:?必须配置 UPGRADE_DATABASE_URL}"
: "${UPGRADE_DEV_URL:?必须配置 UPGRADE_DEV_URL}"
logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT HUP INT TERM

assert_empty() {
  objects=$(psql -X -v ON_ERROR_STOP=1 "$1" -tAc \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema';")
  if [ "$objects" != "0" ]; then
    echo "验证要求使用空的临时数据库" >&2
    exit 1
  fi
}

run_migrations() {
  echo "验证阶段: $1"
  if ! DATABASE_URL="$2" DEV_URL="$3" /db-migrate.sh > "$logs/$1.log" 2>&1; then
    tail -n 80 "$logs/$1.log" >&2
    exit 1
  fi
}

assert_synced() {
  if ! ptah-compat schema diff --from "$1" --to file:///desired_schema.sql \
    --dev-url "$2" \
    --exclude "schema_migrations,alembic_version,atlas_schema_revisions" \
    --format '{{ len .Changes }}' \
    > "$logs/diff.log" 2> "$logs/diff-warnings.log"; then
    cat "$logs/diff.log" >&2
    cat "$logs/diff-warnings.log" >&2
    exit 1
  fi
  # 使用结构化报告中的变更数量，不依赖面向用户的英文日志措辞。
  if [ "$(cat "$logs/diff.log")" != "0" ]; then
    echo "Schema diff 非空，变更数量:" >&2
    cat "$logs/diff.log" >&2
    exit 1
  fi
  # 新库尚无历史工具表时允许 exclude 警告；错误由命令的退出码阻断。
  cat "$logs/diff-warnings.log" >&2
}

object_identity() {
  psql -X -v ON_ERROR_STOP=1 "$1" -tAc \
    "SELECT 'index:'||relname||':'||oid FROM pg_class
       WHERE relname IN ('idx_kb_category_embedding','idx_kbd_entry_embedding')
     UNION ALL
     SELECT 'trigger:'||tgrelid::regclass||':'||tgname||':'||oid FROM pg_trigger
       WHERE NOT tgisinternal
     UNION ALL
     SELECT 'function:'||p.oid::regprocedure||':'||p.oid FROM pg_proc p
       JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND NOT EXISTS
         (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass
          AND d.objid=p.oid AND d.deptype='e') ORDER BY 1;"
}

for url in "$DATABASE_URL" "$DEV_URL" "$UPGRADE_DATABASE_URL" "$UPGRADE_DEV_URL"; do
  assert_empty "$url"
done
test -f /legacy_schema.sql
test -f /legacy_extras.sql
test -f /legacy_migration_035.sql
ptah-compat version

run_migrations fresh "$DATABASE_URL" "$DEV_URL"
psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" -f /verify-ptah-schema.sql
assert_synced "$DATABASE_URL" "$DEV_URL"
psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" -f /verify-ptah-legacy-repairs.sql
assert_synced "$DATABASE_URL" "$DEV_URL"
before=$(object_identity "$DATABASE_URL")
run_migrations repeat "$DATABASE_URL" "$DEV_URL"
assert_synced "$DATABASE_URL" "$DEV_URL"
test "$before" = "$(object_identity "$DATABASE_URL")"
echo "✅ 新建和重复部署保留全部函数、触发器及向量索引的对象标识"

psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" <<'SQL'
DROP TRIGGER update_user_updated_at ON "user";
DROP INDEX idx_kb_category_embedding;
DROP EXTENSION pg_trgm;
CREATE OR REPLACE FUNCTION generate_case_id() RETURNS varchar
LANGUAGE sql AS $$ SELECT 'broken'::varchar $$;
SQL
run_migrations repair "$DATABASE_URL" "$DEV_URL"
psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" -f /verify-ptah-schema.sql
assert_synced "$DATABASE_URL" "$DEV_URL"
echo "✅ 声明的扩展、函数、触发器和 pgvector 索引漂移已修复"

# 从未修改的原始 SQL 重建上游 Schema，不回放历史迁移链。
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" <<'SQL'
CREATE EXTENSION vector;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION "uuid-ossp";
CREATE EXTENSION pg_trgm;
SQL
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /legacy_schema.sql > "$logs/legacy-schema.log" 2>&1
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /legacy_extras.sql > "$logs/legacy-extras.log" 2>&1
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /verify-ptah-upgrade.sql
# 实际执行原迁移，建立真实的旧 checksum 和历史记录。
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -c \
  'DROP TRIGGER update_bundle_metadata_updated_at ON bundle_metadata;'
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /legacy_migration_035.sql > "$logs/legacy-035.log" 2>&1
legacy_checksum=$(sha256sum /legacy_migration_035.sql | cut -d' ' -f1)
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -c \
  "INSERT INTO migration_history(version,checksum,description)
   VALUES('035','$legacy_checksum','上游原始迁移 035');"
run_migrations upgrade "$UPGRADE_DATABASE_URL" "$UPGRADE_DEV_URL"
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /verify-ptah-schema.sql
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM "user" WHERE client_id='ptah-upgrade-sentinel'
    AND metadata='{"preserve":"user-data"}'::jsonb) THEN
    RAISE EXCEPTION '升级丢失了存量用户数据';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM bundle_metadata WHERE support_id='ptah-upgrade-kbd'
    AND bundle_digest='ptah-upgrade-digest' AND compiler_revision='original-revision') THEN
    RAISE EXCEPTION '升级丢失了存量 bundle 数据';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM kbd_batch_job WHERE trace_id='ptah-upgrade-batch'
    AND status='interrupted' AND interrupted_count=1 AND failed_count=0) THEN
    RAISE EXCEPTION '遗留中断任务修复未保留';
  END IF;
END $$;
SQL
assert_synced "$UPGRADE_DATABASE_URL" "$UPGRADE_DEV_URL"
test "$legacy_checksum" = "$(psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -tAc \
  "SELECT checksum FROM migration_history WHERE version='035';")"
before=$(object_identity "$UPGRADE_DATABASE_URL")
run_migrations upgrade-repeat "$UPGRADE_DATABASE_URL" "$UPGRADE_DEV_URL"
assert_synced "$UPGRADE_DATABASE_URL" "$UPGRADE_DEV_URL"
test "$before" = "$(object_identity "$UPGRADE_DATABASE_URL")"
echo "✅ 上游升级保留存量数据、执行遗留修复，重复部署保持同步"

# 保留原有 Helm init，不把两个 ConfigMap 的清理带入上游 PR。
: "${INIT_DATABASE_URL:?必须配置 INIT_DATABASE_URL}"
: "${INIT_DEV_URL:?必须配置 INIT_DEV_URL}"
for init in /legacy_init.sql /legacy_data_init.sql; do
  createdb --maintenance-db "$DATABASE_URL" hci_init
  createdb --maintenance-db "$DATABASE_URL" hci_init_dev
  psql -X -v ON_ERROR_STOP=1 "$INIT_DATABASE_URL" -f "$init" > "$logs/init.log" 2>&1
  run_migrations init "$INIT_DATABASE_URL" "$INIT_DEV_URL"
  psql -X -v ON_ERROR_STOP=1 "$INIT_DATABASE_URL" -f /verify-ptah-schema.sql
  assert_synced "$INIT_DATABASE_URL" "$INIT_DEV_URL"
  dropdb --maintenance-db "$DATABASE_URL" hci_init
  dropdb --maintenance-db "$DATABASE_URL" hci_init_dev
  echo "✅ 原始 Helm init 接管通过: $init"
done
