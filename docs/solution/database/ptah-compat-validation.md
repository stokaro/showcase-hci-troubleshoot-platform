# One PostgreSQL desired state with Ptah Compat

This change replaces the Atlas schema pipeline with the released Ptah Compat
0.11.1 binary. Extensions, functions, and triggers join tables and indexes in
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
produce zero schema diff and preserve function, trigger, and vector-index identities.

An independent catalog comparison covered all 1,225 upstream columns. The
fresh and upgraded catalogs have zero differences in types, defaults, or
nullability. The complete original schema is retained byte for byte in the
combined desired state. Both IVFFlat index
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

## Original SQL retained in Ptah 0.11.1

The initial 0.11.0 rehearsal required changes for Ptah defects. Version 0.11.1
fixes those defects in the shared SQL and comparison code. This change removes
the workarounds rather than asking the application to change valid SQL.

| Declaration retained | Fix in Ptah 0.11.1 |
| --- | --- |
| `bundle_metadata.kbd_id INTEGER` referencing `BIGINT` | PostgreSQL foreign-key validation accepts different compatible integer widths. |
| Both `category_id varchar(32)` references to `varchar(64)` | Foreign-key validation no longer requires the same declared varchar length. |
| All 73 `CURRENT_TIMESTAMP` defaults | The reader retains the keyword instead of rendering invalid empty parentheses. |
| `pending_variable_name DEFAULT NULL` | The reader distinguishes SQL NULL from the string `'NULL'`. |
| `generate_case_id() RETURNS varchar(20)` | Routine comparison accounts for PostgreSQL's discarded modifiers without rewriting the declaration. |

The original table and index SQL is embedded unchanged. Extension declarations
are prepended, and application function and trigger declarations are appended.
Migration `040` has no column-widening statements. The live catalogs are compared
with the original SQL executed independently through psql.

## Reasons for the integration changes

| Change | Reason |
| --- | --- |
| Combine the schema and the object declarations from extras | The desired state must include every object that schema reconciliation owns. |
| Use the released binary in the migration image | The deployment must run the fixes verified here; its archive checksum is checked during the image build. |
| Replace Atlas/extras calls in Compose, Helm, and Make targets | Every deployment path uses the same complete desired state and data-repair order. |
| Remove application DDL from PostgreSQL init ConfigMaps | Initialization must not retain a second copy of definitions now owned by the desired schema. |
| Move existing extras repairs to migration `040` | Retain interrupted-job conversion and obsolete-trigger cleanup after removing the extras file. |
| Make migration `035` use `CREATE OR REPLACE TRIGGER` | A fresh complete schema already contains that trigger; the historical migration must not fail on its second creation. |
| Retain a separate scratch database and set index/exclusion options | Rehearse the plan, preserve `lists=100`, and allow absent historical tool tables on fresh installs. |
| Update verification and migration documentation | Check fresh, repeat, repair, and original-schema upgrade through the actual deployment image. |

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
- Evaluating the SQL NULL default. PostgreSQL stores the original explicit
  declaration as `NULL::character varying`; an absent catalog expression is
  not required. A text value `'NULL'` fails the check.
- Repeating deployment with zero schema diff and unchanged function/trigger/index OIDs.
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
