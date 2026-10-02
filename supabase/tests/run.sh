#!/usr/bin/env bash
# Runs the migration against a throwaway local Postgres database that is
# built to match production before the migration.
#
# Needs: a local Postgres 15+ and psql. Uses the standard PG* variables
# (PGHOST, PGPORT, PGUSER). Never point this at the live project.
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${IQ_TEST_DB:-iq_test}"

dropdb --if-exists "$DB"
createdb "$DB"

psql -q -v ON_ERROR_STOP=1 -d "$DB" -f tests/replica_schema.sql
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f tests/seed_legacy.sql > /dev/null

echo "== preflight =="
psql -At -d "$DB" -f 00_preflight_check.sql

echo "== migration =="
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f 01_migration.sql 2>&1 | grep -v "does not exist, skipping" || true

echo "== tests =="
psql -d "$DB" -f tests/tests.sql 2>&1 | grep -Ev '^\s*(ok:.*)?$'

echo "== cutover rehearsal (production differences reproduced) =="
dropdb --if-exists "${DB}_cutover"
createdb "${DB}_cutover"
psql -q -v ON_ERROR_STOP=1 -d "${DB}_cutover" -f tests/replica_schema.sql
psql -q -v ON_ERROR_STOP=1 -d "${DB}_cutover" -f tests/seed_prod_like.sql > /dev/null
psql -q -v ON_ERROR_STOP=1 -d "${DB}_cutover" -f 01_migration.sql 2>&1 | grep -v "does not exist, skipping" || true
psql -q -v ON_ERROR_STOP=1 -d "${DB}_cutover" -f 02_cutover_corrections.sql > /dev/null
psql -d "${DB}_cutover" -f tests/cutover_tests.sql 2>&1 | grep -E '^(C[0-9]+\.|CUTOVER|psql:.*(ERROR|FATAL))'
