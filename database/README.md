# Database migration management

## Ptah Compat in this fork

[Ptah Compat 0.11.1](https://github.com/stokaro/ptah/releases/tag/v0.11.1)
reconciles extensions, enums, tables, indexes, foreign keys, functions, and triggers
from `database/desired_schema.sql`. The migration image no longer applies
`desired_extras.sql` before and after the schema command.

Read the [migration and validation notes](../docs/solution/database/ptah-compat-validation.md)
for the measured results, reasons for the integration changes, and a reproducible test.

```sh
export PTAH_POSTGRES_INDEX_STORAGE_PARAMS=1
export PTAH_ATLAS_ALLOW_UNMATCHED_EXCLUDE=1
ptah-compat schema diff --env local
ptah-compat schema apply --env local --auto-approve
```

`DATABASE_URL` names the target database. `DEV_URL` must name a separate,
disposable database with the same PostgreSQL version and pgvector installed on
the server. Ptah creates the declared extensions in the databases. No extension
bootstrap or manual scratch-database reset is needed between commands.

`make db-sync`, Docker Compose, and the Helm PreSync Job use the same migration
image. A fresh database first receives the complete desired schema. The entrypoint
then runs the existing versioned data migrations and reconciles the schema again.
An existing database runs its data migrations before the final schema reconciliation.

## File ownership

- `desired_schema.sql` declares the complete PostgreSQL schema.
- `data-migrations/` holds versioned data changes and legacy repairs.
- `data-migrations/040_preserve_legacy_extras_repairs.sql` preserves the repairs
  previously mixed into `desired_extras.sql`, including interrupted batch jobs
  and obsolete Alembic trigger cleanup.
- `atlas-migrations/` and `atlas.sum` remain unchanged historical artifacts.
  The deployment image does not replay them.
- `tests/` verifies the desired objects, trigger behavior, idempotence, drift
  repair, and upgrades from the upstream schema.

Edit the desired schema for object changes. Add a data migration for data repairs.
Review the diff before applying a production change. Production deployment still
runs through the existing Job.

## hci-sim 控制面 Schema（阶段 C/D）

`hci_sim` 数据库的控制面 metadata 按 `control_plane`、`fixture`、`artifact`、`audit` schema 管理：Scenario、不可变 Fixture Bundle、依赖、provenance、审批、审计、TestRun、Attempt、Event、Result 和 Runtime capability。它们只保存精确 revision、受控对象 URI、digest/哈希、状态与审计关联；**禁止**保存原始客户 Artifact、任意外部 URL 或可重放的 Lease 明文。真实 Artifact 进入具备审批、版本与保留策略的对象存储，Runtime 只能读取 `published` Bundle。

当前主库中的 `public.agent_test_*` 是迁移前存量兼容源，复制脚本默认只 inventory；完成 copy/verify/switch 和观察窗口前不得 DROP。独立迁移入口为 `database/hci-sim-migrations/000001_control_plane.sql`，不由平台 Ptah Compat Job 执行。

> The old dbmate `schema_migrations` and Atlas `atlas_schema_revisions` tables
> are historical tool state. Ptah reconciles the desired schema directly; the
> existing `migration_history` table tracks versioned data migrations.

---

## 业务种子数据说明（Seeds）

业务种子数据存放在 `database/seeds/` 目录中，用于在 Admin UI 中初始化工具管理、Prompt管理和技能管理页面，并提供显式标记的诊断测试 KBD 草稿。通过 Helm 部署时，`db-seed-job` 会作为 PostSync Hook 在数据库迁移完成后自动加载这些 SQL 文件。

### 1. 幂等性与覆盖策略

为保护不同环境及用户在管理页面的自定义配置，种子文件遵循以下差异化幂等设计：

| 种子数据文件 | 表名称 | 冲突处理策略 | 覆盖行为说明 |
| :--- | :--- | :--- | :--- |
| `01_tool_definitions.sql` | `tool_definition` | `ON CONFLICT (tool_name) DO UPDATE` | **会被强行覆盖**。工具定义参数与后端 Python 代码严格绑定，必须强制保持一致。 |
| `02_system_prompts.sql` | `system_prompt` | `ON CONFLICT (name) DO NOTHING` | **不会覆盖已有修改**。保护用户在界面微调或自定义的 Prompt 不被冲掉。 |
| `03_skill_definitions.sql` | `skill_definition` | `ON CONFLICT (name) DO NOTHING` | **不会覆盖已有修改**。保护用户自定义技能规则不被重置。 |
| `04_kbd_diagnosis_samples.sql` | `kbd_entry` | 仅升级同样例集且仍为 `draft` 的旧版本 | **只创建待审核草稿，不覆盖已发布、已拒绝或人工维护后的生命周期状态**。样例通过 `metadata.sample_suite` 检索，人工发布后才进入在线诊断，并在 KBD 同步后进入离线诊断。 |

### 2. 手动全量强制更新方法

如果需要丢弃本地或 Staging 环境的已有自定义数据，强制将数据库中的工具、技能和 Prompt 刷新为与最新代码种子文件一致的版本，可使用以下步骤：

1. **清空旧数据**（注意：这会删除所有自定义修改及审计日志）：
   ```bash
   # 在 Kubernetes 中执行
   kubectl exec -i -n hci-dev postgres-0 -- psql -U hci_admin -d hci_troubleshoot -c "TRUNCATE TABLE tool_definition, skill_definition, system_prompt CASCADE;"
   ```
2. **重新导入种子数据**：
   ```bash
   kubectl exec -i -n hci-dev postgres-0 -- psql -U hci_admin -d hci_troubleshoot < database/seeds/01_tool_definitions.sql
   kubectl exec -i -n hci-dev postgres-0 -- psql -U hci_admin -d hci_troubleshoot < database/seeds/02_system_prompts.sql
   kubectl exec -i -n hci-dev postgres-0 -- psql -U hci_admin -d hci_troubleshoot < database/seeds/03_skill_definitions.sql
   ```

### 3. 诊断 KBD 样例集使用方式

`04_kbd_diagnosis_samples.sql` 默认创建 5 篇 `draft`（待审核）KBD，样例集标识为
`diagnosis-signal-matrix-v1`。在 KBD 列表的“样例集标识”中输入该值即可筛出全部样例。
审核发布后的样例会直接用于在线诊断；执行一次离线诊断“KBD 同步与版本”的增量检测并审核派生资源后，
同一批样例即可用于离线诊断。再次加载 Seed 不会覆盖已经人工编辑或发布的样例。

---

## 数据迁移（Data Migration）

> 设计文档：`docs/solution/database/数据迁移设计方案.md`

### 背景

业务演进过程中需要执行数据层面的变更，如：
- 初始化数据补充
- 历史数据修复
- 字段数据回填
- 数据格式转换

这类变更属于 **Data Migration（DML）**，与 Schema Migration（DDL）分离管理。

### 目录结构

```
database/data-migrations/
  001_update_signals_prompt_stage.sql
  002_xxx.sql
  ...
```

### 命名规范

格式：`{version}_{description}.sql`

- `version`：三位数字，永远递增（001, 002, 003...）
- `description`：简短描述，使用下划线分隔

### 幂等性规范（强制）

所有数据迁移脚本**必须可安全重复执行**：

```sql
-- ❌ 错误：第二次执行失败
INSERT INTO config VALUES ('feature_x', 'true');

-- ✅ 正确：幂等
INSERT INTO config (key, value)
VALUES ('feature_x', 'true')
ON CONFLICT(key) DO NOTHING;
```

```sql
-- ✅ UPDATE 必须有 WHERE 条件
UPDATE system_prompt
SET stage = 'KEY'
WHERE name = 'kbd_extract_signals_v1'
  AND stage = 'KBD';
```

### 执行机制

数据迁移通过 `migration-runner.sh` 在 db-migrate Job 中执行：

1. 启动时检查 `migration_history` 表
2. 扫描 `data-migrations/` 目录
3. 按版本号顺序执行未执行的迁移
4. 记录执行历史（version, checksum, executed_at）

### migration_history 表

```sql
CREATE TABLE IF NOT EXISTS migration_history (
    version VARCHAR(100) PRIMARY KEY,
    checksum VARCHAR(64),
    description VARCHAR(255),
    executed_at TIMESTAMP DEFAULT NOW(),
    execution_time_ms INTEGER
);
```

### 开发流程

1. **新增数据迁移**：在 `database/data-migrations/` 下新建文件
2. **本地测试**：`psql -f database/data-migrations/xxx.sql`
3. **提交 PR**：CI 自动验证
4. **合并后自动执行**：ArgoCD PreSync Hook

### 注意事项

- 禁止修改已执行的迁移文件
- 新需求必须新增文件
- 大数据量迁移需分批处理
- 生产问题采用 Forward Fix，不回滚
