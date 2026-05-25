#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/.test-pg"
DATA_DIR="${STATE_DIR}/data"
LOG_FILE="${STATE_DIR}/postgres.log"
PID_FILE="${STATE_DIR}/postgres.pid"
ENV_FILE="${STATE_DIR}/env.sh"
SCHEMA_FILE="${ROOT_DIR}/test/sql/test_schema.sql"

PGHOST_VALUE="${PGHOST_VALUE:-127.0.0.1}"
PGPORT_VALUE="${PGPORT_VALUE:-55432}"
PGUSER_VALUE="${PGUSER_VALUE:-pgtest}"
PGDATABASE_VALUE="${PGDATABASE_VALUE:-pgtest}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

require_cmd initdb
require_cmd postgres
require_cmd psql

mkdir -p "${STATE_DIR}"

if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    printf 'Test PostgreSQL is already running.\n' >&2
    printf '%s\n' "${ENV_FILE}"
    exit 0
fi

rm -rf "${DATA_DIR}"
mkdir -p "${DATA_DIR}"

initdb -D "${DATA_DIR}" --username=postgres --auth=trust >/dev/null

cat > "${DATA_DIR}/postgresql.conf" <<EOF
listen_addresses = '${PGHOST_VALUE}'
port = ${PGPORT_VALUE}
unix_socket_directories = '${STATE_DIR}'
fsync = off
synchronous_commit = off
full_page_writes = off
log_min_messages = warning
EOF

cat > "${DATA_DIR}/pg_hba.conf" <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF

postgres -D "${DATA_DIR}" >"${LOG_FILE}" 2>&1 &
POSTGRES_PID=$!
printf '%s\n' "${POSTGRES_PID}" > "${PID_FILE}"

cleanup_failed_start() {
    if kill -0 "${POSTGRES_PID}" 2>/dev/null; then
        kill "${POSTGRES_PID}" 2>/dev/null || true
        wait "${POSTGRES_PID}" 2>/dev/null || true
    fi
}

trap cleanup_failed_start EXIT

for _ in $(seq 1 100); do
    if psql -h "${PGHOST_VALUE}" -p "${PGPORT_VALUE}" -U postgres -d postgres -Atqc "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

psql -h "${PGHOST_VALUE}" -p "${PGPORT_VALUE}" -U postgres -d postgres -v ON_ERROR_STOP=1 <<EOF >/dev/null
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PGUSER_VALUE}') THEN
        EXECUTE format('CREATE ROLE %I LOGIN', '${PGUSER_VALUE}');
    END IF;
END
\$\$;
EOF

if ! psql -h "${PGHOST_VALUE}" -p "${PGPORT_VALUE}" -U postgres -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname = '${PGDATABASE_VALUE}'" | grep -q 1; then
    createdb -h "${PGHOST_VALUE}" -p "${PGPORT_VALUE}" -U postgres -O "${PGUSER_VALUE}" "${PGDATABASE_VALUE}"
fi

psql -h "${PGHOST_VALUE}" -p "${PGPORT_VALUE}" -U postgres -d "${PGDATABASE_VALUE}" -v ON_ERROR_STOP=1 -f "${SCHEMA_FILE}" >/dev/null

cat > "${ENV_FILE}" <<EOF
export PGHOST="${PGHOST_VALUE}"
export PGPORT="${PGPORT_VALUE}"
export PGUSER="${PGUSER_VALUE}"
export PGDATABASE="${PGDATABASE_VALUE}"
EOF

trap - EXIT
printf '%s\n' "${ENV_FILE}"
