# One PostgreSQL desired state with Ptah Compat

This fork replaces the Atlas schema pipeline with the released Ptah Compat
0.11.0 binary. Extensions, functions, and triggers join tables and indexes in
`database/desired_schema.sql`. Deployment no longer runs `desired_extras.sql`
before and after the schema command.

The source is `tomturing/hci-troubleshoot-platform` at
[`4ca96cbf27f1d8d24c63429a596849a97ab9011e`](https://github.com/tomturing/hci-troubleshoot-platform/tree/4ca96cbf27f1d8d24c63429a596849a97ab9011e).
The original [Atlas Community limitation report](../events/2026-04-09-atlas声明式schema真正实现.md)
explains why these objects were separated.

## Measured result

The migration image passed fresh-install, repeat, drift-repair, and upstream-upgrade
checks on PostgreSQL 15.19 with pgvector 0.8.6. It ran as UID 65534. Both fresh and
upgraded databases contain 76 tables, four application functions, 24 enabled
application triggers, and all four declared extensions. Repeated deployments
produce zero schema diff and preserve trigger and vector-index identities.

An independent catalog comparison covered all 1,225 upstream columns. The
differences are the three widened columns, 73 equivalent timestamp defaults, and
the explicit-to-implicit SQL NULL default listed below. Both IVFFlat index
definitions match the upstream PostgreSQL catalog, including `vector_cosine_ops`,
`lists=100`, and the `published` filter on the knowledge-entry index.

A control using Atlas Community 1.3.1, the version in the upstream deployment
image, received the same combined object declarations. With the required
extensions preinstalled in its target database, it created 76 tables but no
application functions or triggers. This was a successful command that omitted
those objects. The control establishes the need for the existing workaround.

## Deployment behavior

`Dockerfile.migrations` downloads the release archive and verifies its SHA-256
against the release checksums. The migration entrypoint calls:

```sh
ptah-compat schema apply \
  --url "$DATABASE_URL" \
  --to file:///desired_schema.sql \
  --dev-url "$DEV_URL" \
  --exclude "schema_migrations,alembic_version,atlas_schema_revisions" \
  --auto-approve
```

The image and entrypoint set these documented options:

- `PTAH_POSTGRES_INDEX_STORAGE_PARAMS=1` retains pgvector's `lists=100`.
  It prevents repeated rebuilds caused by omitted storage parameters.
- `PTAH_ATLAS_ALLOW_UNMATCHED_EXCLUDE=1` allows the historical tool-table
  exclusions when those tables do not exist, including on a fresh installation.

The separate scratch database is still named `atlas_dev` in existing Compose
and Helm configuration. Ptah rehearses the complete plan there before changing
the target. It installs the declared extensions itself and cleans the scratch
state. The explicit extension bootstrap and reset loops have been removed.

The PostgreSQL init ConfigMaps no longer contain copies of application schema
objects. The migration Job owns them. The same pgvector-enabled server image
and database permissions remain necessary.

## SQL adjustments required by Ptah 0.11.0

The unmodified schema did not pass Ptah's validation. This fork makes the
following changes; this is a measured adaptation of the schema, not a claim
that replacing the executable alone works.

| Declaration | Upstream | This fork | Reason |
| --- | --- | --- | --- |
| `bundle_metadata.kbd_id` | `INTEGER` | `BIGINT` | Match the referenced `kbd_entry.id` storage type. Ptah refuses the mixed integer widths. |
| `kbd_entry.category_id` | `varchar(32)` | `varchar(64)` | Match `kb_category.code`. Ptah refuses different declared lengths. |
| `sop_document.category_id` | `varchar(32)` | `varchar(64)` | Match the same referenced category key. |
| Timestamp defaults | `CURRENT_TIMESTAMP` | `now()` | Ptah's SQL reader rendered the former as invalid PostgreSQL `CURRENT_TIMESTAMP()`. |
| `sop_execution.pending_variable_name` default | `DEFAULT NULL` | Implicit SQL NULL default | The SQL reader treated the explicit NULL as the text value `'NULL'`. Omitting it retains the original PostgreSQL meaning. |
| `generate_case_id()` return type | `varchar(20)` | `varchar` | PostgreSQL discards function return-type modifiers; retaining it caused a repeated drop/recreate plan in Ptah. |

The column changes widen storage and keep existing values. Migration `040`
performs the widening before Ptah rehearses the original baseline; that baseline
hit the same foreign-key validation as the desired schema. PostgreSQL itself
accepts the original foreign keys, as the upgrade fixture verifies.
[PostgreSQL documents `now()` and `CURRENT_TIMESTAMP` as equivalent](https://www.postgresql.org/docs/15/functions-datetime.html#FUNCTIONS-DATETIME-CURRENT).
It also documents that
[`CREATE FUNCTION` discards parenthesized type modifiers](https://www.postgresql.org/docs/15/sql-createfunction.html).
The timestamp and function spelling changes preserve PostgreSQL behavior.

## Existing installations and data migrations

A fresh database receives the complete schema before running data migrations.
An existing database runs its data migrations before final schema reconciliation,
so existing rows are repaired before new constraints are applied.

`desired_extras.sql` contained data repairs as well as schema objects. The
repairs move to `data-migrations/040_preserve_legacy_extras_repairs.sql` and run
through the existing migration-history mechanism. This preserves interrupted
batch-job conversion and removes obsolete Alembic triggers that could double
message counts. The schema DDL in data migration `035` now uses `CREATE OR REPLACE TRIGGER`,
which PostgreSQL 15 supports. Its old unconditional CREATE collided with a
trigger already installed by the complete desired state. Previously recorded
migration-history rows are retained and remain skipped by version. Fresh
installations record the updated file checksum. The other earlier data migration
files and all historical `atlas-migrations/` files and `atlas.sum` are unchanged.

## Reproduce the verification

The `DB Schema verification` workflow builds the `schema-test` target of the
same Dockerfile as deployment. It runs as UID 65534, matching the Helm Job.
The test uses separate empty target and scratch databases on PostgreSQL 15 with
pgvector. No external embedding provider or application deployment is needed.

For a manual run, build the target on your selected Docker context:

```sh
docker --context remote-dev-container build \
  --build-arg MIRROR_MODE=off --target schema-test \
  -f Dockerfile.migrations -t hci-db-migrate-verify .
```

Create separate disposable databases and pass their URLs as `DATABASE_URL`,
`DEV_URL`, `UPGRADE_DATABASE_URL`, and `UPGRADE_DEV_URL`. Provide these unchanged
upstream files inside the verification container as `/legacy_schema.sql`,
`/legacy_extras.sql`, and `/legacy_migration_035.sql`:

```sh
git show 4ca96cbf27f1d8d24c63429a596849a97ab9011e:database/desired_schema.sql > /tmp/legacy_schema.sql
git show 4ca96cbf27f1d8d24c63429a596849a97ab9011e:database/desired_extras.sql > /tmp/legacy_extras.sql
git show 4ca96cbf27f1d8d24c63429a596849a97ab9011e:database/data-migrations/035_bundle_factory_version_metadata.sql > /tmp/legacy_migration_035.sql
```

Use `docker cp` for remote Docker hosts; a bind mount uses the daemon's
filesystem. Run `/verify-ptah-schema.sh` as the container entrypoint. It refuses
nonempty databases before starting. See the workflow for the complete runner
configuration.

The verification covers:

- Creating the full schema, including application functions, enabled triggers,
  extensions, and both IVFFlat indexes with their storage parameters.
- Exercising `updated_at`, case-ID generation, and message INSERT/DELETE counting.
- Repeating deployment with zero schema diff and unchanged trigger/index OIDs.
- Repairing a removed extension, replaced function, removed trigger, and removed
  vector index through the same declarative entrypoint.
- Loading the unchanged upstream schema and extras, adding representative existing
  rows and obsolete Alembic triggers, then upgrading without losing those rows.
- Retaining the checksum of an actually executed original migration `035`.
- Preserving the legacy interrupted-job repair and repeating the upgraded deployment
  with zero diff and stable object identities.

The local measurements and exact inputs are recorded in
[the verification results](ptah-compat-results.json). These checks establish
schema management for this repository. They do not measure application load,
embedding-provider behavior, or production deployment.
