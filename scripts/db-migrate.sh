#!/bin/sh
# Bootstrap a fresh database, run versioned data repairs, then reconcile the schema.
# Existing installations retain the data-before-constraints upgrade order.
set -eu
: "${DATABASE_URL:?DATABASE_URL is required}"
: "${DEV_URL:?DEV_URL must name a separate disposable database}"
export PTAH_POSTGRES_INDEX_STORAGE_PARAMS=1
# Historical tool tables are absent on fresh installs.
export PTAH_ATLAS_ALLOW_UNMATCHED_EXCLUDE=1

apply_schema() {
  ptah-compat schema apply \
    --url "$DATABASE_URL" \
    --to file:///desired_schema.sql \
    --dev-url "$DEV_URL" \
    --exclude "schema_migrations,alembic_version,atlas_schema_revisions" \
    --auto-approve
}

echo "HCI database migration with Ptah Compat"
core_schema_ready=$(psql -X -v ON_ERROR_STOP=1 "$DATABASE_URL" -tAc \
  "SELECT to_regclass('public.tool_definition') IS NOT NULL;")
if [ "$core_schema_ready" != "t" ]; then
  echo "Bootstrapping the complete desired state for a fresh database"
  apply_schema
fi

echo "Applying versioned data migrations"
/migration-runner.sh
echo "Reconciling extensions, tables, functions, and triggers"
apply_schema
echo "Database migration completed"
