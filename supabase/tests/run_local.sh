#!/usr/bin/env bash
# Runs all migrations + database tests on a THROW-AWAY local PostgreSQL 15+/16.
# Usage: PGHOST=localhost PGPORT=5432 PGUSER=postgres ./supabase/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TEST_DB:-accessories_sahiwal_test}
PSQL="psql -v ON_ERROR_STOP=1 -q -t"
$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d "$DB" -f tests/00_local_supabase_stubs.sql
for f in migrations/*.sql; do echo "migrate: $f"; $PSQL -d "$DB" -f "$f"; done
for f in tests/[1-9]*_test.sql; do echo "test: $f"; $PSQL -d "$DB" -f "$f" 2>&1 | grep -E 'ok - |PASSED|ERROR|FAILED' | sed 's/^psql:[^ ]* NOTICE:  //'; done
