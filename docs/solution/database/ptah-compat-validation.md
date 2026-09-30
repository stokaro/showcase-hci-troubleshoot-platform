# Ptah Compat：统一 PostgreSQL 期望状态与迁移验证

Ptah Compat **0.11.1** 管理 `database/desired_schema.sql` 中的完整期望状态。
扩展、函数、触发器与表、索引一起声明式收敛，不再前后两次执行 `desired_extras.sql`。
基线为上游 [`4ca96cbf`](https://github.com/tomturing/hci-troubleshoot-platform/tree/4ca96cbf27f1d8d24c63429a596849a97ab9011e)；
[原 Atlas Community 限制记录](../events/2026-04-09-atlas声明式schema真正实现.md)说明了拆分原因。

## 验证结果

正式发布的二进制及实际迁移镜像在 PostgreSQL 15.19 / pgvector 0.8.6 上通过新建、重复、
漂移修复和原始 Schema 升级验证。进程 UID 为 65534，与 Helm Job 一致。

- 新建和升级后均有 76 张表、4 个声明扩展、4 个应用函数及 24 个启用的应用触发器。
- 对照独立执行原始 SQL 得到的 catalog，全部 1,225 个列的类型、默认值、可空性零差异。
- 重复部署后零 Schema diff，函数、触发器、向量索引共 30 个对象的 OID 保持不变。
- 两个 IVFFlat 索引保留 `vector_cosine_ops`、`lists=100` 及知识条目索引的 `published` 过滤条件。
- 行为验证覆盖 `updated_at`、工单编号、消息 INSERT/DELETE 只计数一次、SQL NULL 默认值、
  代表性存量数据保留、中断任务修复及原迁移 `035` 的历史 checksum 保留。

Atlas Community 1.3.1 对照实验使用相同的合并 SQL，并在目标库和临时库预装必要扩展。
命令成功结束，创建了 76 张表，但没有创建应用函数或触发器，与原拆分方案的原因一致。

## 保留原始 SQL

初次用 0.11.0 验证时需要绕过 Ptah 自身缺陷。0.11.1 已在共享 SQL 读取和比较代码中修复，
因此保留原始表和索引 SQL 的全部字节，不要求应用改写合法声明。

| 保留的声明 | Ptah 0.11.1 修复 |
| --- | --- |
| `bundle_metadata.kbd_id INTEGER` 引用 `BIGINT` | 接受 PostgreSQL 支持的不同整数宽度外键。 |
| 两处 `category_id varchar(32)` 引用 `varchar(64)` | 不再要求外键两侧 varchar 长度相同。 |
| 全部 73 个 `CURRENT_TIMESTAMP` 默认值 | 保留关键字，不再生成无效的空括号调用。 |
| `pending_variable_name DEFAULT NULL` | 区分 SQL NULL 与字符串 `'NULL'`。 |
| `generate_case_id() RETURNS varchar(20)` | 比较函数时考虑 PostgreSQL 丢弃的类型修饰符，不改写声明。 |

扩展声明加在原文件前，应用函数和触发器声明加在原文件后。迁移 `040` 不含列宽调整。
SQL NULL 验证允许 PostgreSQL 将显式默认值存为 `NULL::character varying`，但拒绝字符串 `'NULL'`。

## 集成改动及原因

| 改动 | 原因 |
| --- | --- |
| 合并 Schema 与 extras 中的对象声明 | 声明式管理必须包含全部归其管理的对象。 |
| 迁移镜像使用正式 0.11.1 发布包并校验 SHA-256 | 部署与验证使用包含上述修复的相同版本。 |
| Compose、Helm、Make 统一迁移入口 | 各入口使用同一期望状态及数据修复顺序。 |
| 删除 PostgreSQL init ConfigMap 中重复的应用 DDL | 对象由迁移 Job 管理，避免维护另一份定义。 |
| 原 extras 数据修复移入迁移 `040` | 保留中断任务转换和废弃 Alembic 触发器清理，避免消息双倍计数。 |
| 迁移 `035` 使用 `CREATE OR REPLACE TRIGGER` | 新库完整 Schema 已有该触发器，原 CREATE 会发生同名冲突。 |
| 保留独立临时库及索引/排除选项 | 预演计划，保留 `lists=100`，允许新库不存在历史工具表。 |
| 增加镜像验证及更新相关文档 | 覆盖新建、重复、漂移修复和原始 Schema 升级。 |

## 部署和存量迁移

`Dockerfile.migrations` 下载正式发布包并按发布 checksums 校验 SHA-256。入口调用：

```sh
ptah-compat schema apply \
  --url "$DATABASE_URL" \
  --to file:///desired_schema.sql \
  --dev-url "$DEV_URL" \
  --exclude "schema_migrations,alembic_version,atlas_schema_revisions" \
  --auto-approve
```

- `PTAH_POSTGRES_INDEX_STORAGE_PARAMS=1` 保留 `lists=100` 等索引存储参数，避免重复重建。
- `PTAH_ATLAS_ALLOW_UNMATCHED_EXCLUDE=1` 允许新库尚不存在历史工具表时继续使用原排除列表。

`DEV_URL` 仍指向独立的 `atlas_dev` 临时数据库。Ptah 在其中预演完整计划并管理扩展和清理。
服务器仍需安装 pgvector 等扩展二进制，迁移用户仍需相应权限；不能把临时库 URL 指向目标库。

新库先创建完整 Schema，再执行数据迁移、最终收敛；存量库先执行数据迁移，再收敛约束。
原 extras 数据修复移至 `040_preserve_legacy_extras_repairs.sql`，继续由原 migration-history 机制管理。
迁移 `035` 仅将触发器创建改为 `CREATE OR REPLACE TRIGGER`（PostgreSQL 15 支持）：已执行版本仍被
runner 跳过，历史 checksum 保留；新安装记录更新后的 checksum。其他旧数据迁移和历史
`atlas-migrations/`、`atlas.sum` 均未修改。

## 复现验证

`DB Schema 声明式验证` workflow 构建同一 Dockerfile 的 `schema-test` 阶段，以 UID 65534 运行。
验证要求目标库和临时库为空，且 PostgreSQL 15 服务器已安装 pgvector 二进制。

手动运行时请选择自己的 Docker context；以下示例使用 `remote-dev-container`：

```sh
docker --context remote-dev-container build \
  --build-arg MIRROR_MODE=off --target schema-test \
  -f Dockerfile.migrations -t hci-db-migrate-verify .
```

创建独立的临时数据库，传入 `DATABASE_URL`、`DEV_URL`、`UPGRADE_DATABASE_URL`、`UPGRADE_DEV_URL`。
将以下未修改的原始上游文件放入验证容器的 `/legacy_schema.sql`、`/legacy_extras.sql`、
`/legacy_migration_035.sql`：

```sh
git show 4ca96cbf27f1d8d24c63429a596849a97ab9011e:database/desired_schema.sql > /tmp/legacy_schema.sql
git show 4ca96cbf27f1d8d24c63429a596849a97ab9011e:database/desired_extras.sql > /tmp/legacy_extras.sql
git show 4ca96cbf27f1d8d24c63429a596849a97ab9011e:database/data-migrations/035_bundle_factory_version_metadata.sql > /tmp/legacy_migration_035.sql
```

远程 Docker daemon 使用 `docker cp` 传文件，bind mount 的路径属于 daemon 主机。
运行 `/verify-ptah-schema.sh` 作为入口；脚本拒绝非空数据库。完整 runner 配置见 workflow。

原始测量输入、SHA-256、catalog 对照和原始输出固定保存在
[验证结果快照（2dbc048e）](https://github.com/stokaro/showcase-hci-troubleshoot-platform/blob/2dbc048e70eae5782dc600800bbfa6dbeeadaa38/docs/solution/database/ptah-compat-results.json)，
不在应用仓库重复存放测量 JSON。后续中文注释和日志调整不改写该快照。
这些检查验证数据库 Schema 和迁移行为，未覆盖应用负载、外部 embedding provider、Kubernetes 或生产部署。
