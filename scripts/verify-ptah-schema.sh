#!/bin/sh
# Run inside the schema-test image against separate, empty disposable databases.
set -eu
: "${DATABASE_URL:?DATABASE_URL is required}"
: "${DEV_URL:?DEV_URL is required}"
: "${UPGRADE_DATABASE_URL:?UPGRADE_DATABASE_URL is required}"
: "${UPGRADE_DEV_URL:?UPGRADE_DEV_URL is required}"
export PTAH_POSTGRES_INDEX_STORAGE_PARAMS=1
# Historical tool tables are absent on fresh installs.
export PTAH_ATLAS_ALLOW_UNMATCHED_EXCLUDE=1
logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT HUP INT TERM

assert_empty() {
  objects=$(psql -X -v ON_ERROR_STOP=1 "$1" -tAc \
    "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname <> 'information_schema';")
  if [ "$objects" != "0" ]; then
    echo "Verification requires empty disposable databases" >&2
    exit 1
  fi
}

run_migrations() {
  echo "Testing $1"
  if ! DATABASE_URL="$2" DEV_URL="$3" /db-migrate.sh > "$logs/$1.log" 2>&1; then
    tail -n 80 "$logs/$1.log" >&2
    exit 1
  fi
}

assert_synced() {
  if ! ptah-compat schema diff --from "$1" --to file:///desired_schema.sql \
    --dev-url "$2" \
    --exclude "schema_migrations,alembic_version,atlas_schema_revisions" \
    > "$logs/diff.log" 2> "$logs/diff-warnings.log"; then
    cat "$logs/diff.log" >&2
    cat "$logs/diff-warnings.log" >&2
    exit 1
  fi
  if [ "$(cat "$logs/diff.log")" != "Schemas are synced, no changes to be made." ]; then
    cat "$logs/diff.log" >&2
    exit 1
  fi
  warnings=$(cat "$logs/diff-warnings.log")
  expected_warning='Warning: the --exclude selection matched no objects: "schema_migrations", "alembic_version", "atlas_schema_revisions".'
  if [ -n "$warnings" ] && [ "$warnings" != "$expected_warning" ]; then
    cat "$logs/diff-warnings.log" >&2
    exit 1
  fi
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
before=$(object_identity "$DATABASE_URL")
run_migrations repeat "$DATABASE_URL" "$DEV_URL"
assert_synced "$DATABASE_URL" "$DEV_URL"
test "$before" = "$(object_identity "$DATABASE_URL")"
echo "PASS: fresh install and repeat preserve every function, trigger, and vector index"

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
echo "PASS: declared extension, function, trigger, and pgvector index drift is repaired"

# Recreate the upstream schema without modifying its SQL or replaying history.
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" <<'SQL'
CREATE EXTENSION vector;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION "uuid-ossp";
CREATE EXTENSION pg_trgm;
SQL
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /legacy_schema.sql > "$logs/legacy-schema.log" 2>&1
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /legacy_extras.sql > "$logs/legacy-extras.log" 2>&1
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /verify-ptah-upgrade.sql
# Execute the original migration to establish a genuine old checksum/history row.
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -c \
  'DROP TRIGGER update_bundle_metadata_updated_at ON bundle_metadata;'
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /legacy_migration_035.sql > "$logs/legacy-035.log" 2>&1
legacy_checksum=$(sha256sum /legacy_migration_035.sql | cut -d' ' -f1)
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -c \
  "INSERT INTO migration_history(version,checksum,description)
   VALUES('035','$legacy_checksum','Original upstream migration 035');"
run_migrations upgrade "$UPGRADE_DATABASE_URL" "$UPGRADE_DEV_URL"
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" -f /verify-ptah-schema.sql
psql -X -v ON_ERROR_STOP=1 "$UPGRADE_DATABASE_URL" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM "user" WHERE client_id='ptah-upgrade-sentinel'
    AND metadata='{"preserve":"user-data"}'::jsonb) THEN
    RAISE EXCEPTION 'Upgrade lost the existing user row';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM bundle_metadata WHERE support_id='ptah-upgrade-kbd'
    AND bundle_digest='ptah-upgrade-digest' AND compiler_revision='original-revision') THEN
    RAISE EXCEPTION 'Upgrade lost the existing bundle row';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM kbd_batch_job WHERE trace_id='ptah-upgrade-batch'
    AND status='interrupted' AND interrupted_count=1 AND failed_count=0) THEN
    RAISE EXCEPTION 'Legacy interrupted-job repair was lost';
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
echo "PASS: upstream upgrade preserves data, runs legacy repairs, and stays synchronized"
