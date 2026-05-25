#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/.test-pg"
ENV_FILE="${STATE_DIR}/env.sh"
RESET_FILE="${ROOT_DIR}/test/sql/reset.sql"
SCHEMA_FILE="${ROOT_DIR}/test/sql/test_schema.sql"

if [[ ! -f "${ENV_FILE}" ]]; then
    printf 'Test PostgreSQL environment is not running.\n' >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 -f "${RESET_FILE}" >/dev/null
psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -v ON_ERROR_STOP=1 -f "${SCHEMA_FILE}" >/dev/null
