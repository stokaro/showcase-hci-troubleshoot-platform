# Ptah 0.11.1 接管复验（仅证明分支）

本分支直接基于上游 PR #1107 的精简提交 `96f46324`，生产文件与该提交一致。
`proof/` 与本分支的 DB workflow 不进入上游 PR，避免给应用添加另一套长期维护的验证框架。

通过 `workflow_dispatch` 运行 `.github/workflows/db-migration-test.yml`。验证使用正式发布包及实际部署镜像，包含：

- diagnosis-service 全部 unit 测试。
- 新建、重复部署、对象 OID 保留、漂移修复和从切换前原始 SQL 升级。
- 旧 CHECK 扩展、未来 CHECK 保留、模拟 041 使用新值，以及不同 schema 的同名列。
- 用旧 040 运行同一回归场景，确认测试确实拒绝有缺陷的迁移。
- 两套原始 Helm init SQL 接管后业务行为正常、Schema diff 为零。

原始 SQL 来自固定的 `PRE_PTAH_BASELINE`，对照迁移来自 `289b3416`。历史证据不随未来 Schema 演进。
数据库均为工作流内临时 PostgreSQL 15 / pgvector 实例；这里未部署 Kubernetes 或真实应用。
