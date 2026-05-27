SHELL := /bin/bash

SWIPL ?= swipl
PGHOST ?= 127.0.0.1
PGPORT ?= 5432
PGUSER ?= postgres
PGPASSWORD ?=
PGDATABASE ?= postgres
TEST_PG_AUTH ?= trust
TEST_PG_PASSWORD ?= pgtest
TEST_PG_ENV_FILE := .test-pg/env.sh
PACK_PATH_SETUP = asserta(user:file_search_path(library,'prolog'))

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
RELEASE_NAME := postgresql-prolog-$(VERSION)
RELEASE_FILE := dist/$(RELEASE_NAME).tar.gz

TEST_ENV = PGHOST="$(PGHOST)" PGPORT="$(PGPORT)" PGUSER="$(PGUSER)" PGPASSWORD="$(PGPASSWORD)" PGDATABASE="$(PGDATABASE)"
SWIPL_TEST = $(SWIPL) -q -g "$(PACK_PATH_SETUP), ['test/test_postgresql.pl'], test_postgresql:run_all_tests, halt."
SWIPL_COVERAGE = $(SWIPL) -q -g "$(PACK_PATH_SETUP), use_module(library(prolog_coverage)), ['test/test_postgresql.pl'], coverage(test_postgresql:run_all_tests,[dir('coverage')]), show_coverage(['prolog/postgresql_prolog/pg.pl','prolog/postgresql_prolog/pg_protocol.pl','prolog/postgresql_prolog/pg_types.pl','test/test_postgresql.pl']), halt."
SWIPL_SMOKE = $(SWIPL) -q -g "$(PACK_PATH_SETUP), use_module(library(postgresql_prolog/pg)), pg:pg_connect('$(PGHOST)':$(PGPORT), C, [user(\"$(PGUSER)\"),password(\"$(PGPASSWORD)\"),database(\"$(PGDATABASE)\")]), pg:pg_query(C, \"SELECT 1 AS n\", R), write_term(R,[quoted(true)]), nl, pg:pg_disconnect(C), halt."

.PHONY: smoke test coverage release clean test-local-pg test-local-pg-md5 start-test-postgres stop-test-postgres reset-test-postgres

smoke:
	@$(TEST_ENV) $(SWIPL_SMOKE)

test:
	@$(TEST_ENV) $(SWIPL_TEST)

coverage:
	@mkdir -p coverage
	@set -o pipefail; $(TEST_ENV) $(SWIPL_COVERAGE) | tee coverage/summary.txt

start-test-postgres:
	@TEST_PG_AUTH="$(TEST_PG_AUTH)" TEST_PG_PASSWORD="$(TEST_PG_PASSWORD)" bash "scripts/start_test_postgres.sh" >/dev/null
	@printf 'Started local test PostgreSQL. Env file: %s\n' "$(TEST_PG_ENV_FILE)"

stop-test-postgres:
	@bash "scripts/stop_test_postgres.sh"

reset-test-postgres:
	@bash "scripts/reset_test_postgres.sh"

test-local-pg:
	@TEST_PG_AUTH="$(TEST_PG_AUTH)" TEST_PG_PASSWORD="$(TEST_PG_PASSWORD)" bash "scripts/start_test_postgres.sh" >/dev/null
	@trap 'bash "scripts/stop_test_postgres.sh"' EXIT; source "$(TEST_PG_ENV_FILE)"; $(SWIPL_TEST)

test-local-pg-md5:
	@$(MAKE) test-local-pg TEST_PG_AUTH=md5 TEST_PG_PASSWORD="$(TEST_PG_PASSWORD)"

release:
	@mkdir -p dist
	@tar --exclude='./dist' --exclude='./coverage' --exclude-vcs -czf "$(RELEASE_FILE)" .
	@printf 'Created %s\n' "$(RELEASE_FILE)"

clean:
	@rm -rf coverage dist .test-pg
