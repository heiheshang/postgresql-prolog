# postgresql-prolog

[![CI](https://github.com/heiheshang/postgresql-prolog/actions/workflows/test.yml/badge.svg)](https://github.com/heiheshang/postgresql-prolog/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/heiheshang/postgresql-prolog)](https://github.com/heiheshang/postgresql-prolog/releases)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?logo=postgresql&logoColor=white)](https://github.com/postgres/postgres)
[![SWI-Prolog](https://img.shields.io/badge/SWI--Prolog-E61B23?logo=prolog&logoColor=white)](https://github.com/SWI-Prolog/swipl-devel)

PostgreSQL driver for SWI-Prolog with support for simple queries, prepared statements, LISTEN/NOTIFY, `COPY FROM STDIN`, and `COPY TO STDOUT`.

The active driver module is `pg`, provided by `library(postgresql_prolog/pg)`.

## Contents

- [Status](#status)
- [Quick Start](#quick-start)
- [API Overview](#api-overview)
- [Examples](#examples)
- [Notes](#notes)
- [Architecture](#architecture)
- [Authentication](#authentication)
- [Testing and Development](#testing-and-development)
- [Repository Layout](#repository-layout)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Status

This project is usable for development and experimentation, but it is still evolving.

Implemented now:

- connect / disconnect
- simple query protocol
- prepared statements and parameterized queries
- explicit session state and protocol-phase tracking via `pg_session.pl`
- unified message-reading and recovery to `ReadyForQuery`
- cleartext password, `md5`, and SCRAM-SHA-256 (SASL) authentication
- basic result decoding for `int4`, `int8`, `text`, `varchar`, `bool`, and `null`
- LISTEN / NOTIFY
- `COPY FROM STDIN` for text, csv, and binary input via `pg_copy.pl`
- streaming `COPY TO STDOUT` via callback-driven `pg_copy_to/3`
- metadata helpers for backend PID, server parameters, and last command tag
- cancel API via `pg_cancel/1`
- recovery after simple-query, extended-query, and server-side COPY errors

Not implemented yet:

- SCRAM channel binding (`SCRAM-SHA-256-PLUS`)
- SSL
- binary result formats for extended query mode

See `ROADMAP.md` for the planned architecture steps.

## Quick Start

Load the driver:

```prolog
:- use_module(library(postgresql_prolog/pg)).
```

For local development from a checkout, add the repository `prolog/` directory to the library search path first:

```prolog
:- asserta(user:file_search_path(library, 'prolog')).
:- use_module(library(postgresql_prolog/pg)).
```

Connect and run a query:

```prolog
:- use_module(library(postgresql_prolog/pg)).

demo :-
    pg_connect('127.0.0.1':5432, Conn,
        [ user("postgres"),
          password("secret"),
          database("postgres")
        ]),
    pg_query(Conn, "SELECT 1 AS n", Result),
    writeln(Result),
    pg_disconnect(Conn).
```

Example result:

```prolog
data([col{name:"n",type_oid:23,...}], [[1]])
```

## API Overview

Main predicates:

```prolog
pg_connect(+HostPort, -Connection, +Options)
pg_disconnect(+Connection)

pg_query(+Connection, +SQL, -Result)
pg_query(+Connection, +SQL, +Params, -Result)

pg_prepare(+Connection, +Name, +SQL, +ParamTypes)
pg_execute(+Connection, +Name, +Params, -Result)

pg_listen(+Connection, +Channel, +Handler)
pg_wait_for_notification(+Connection, +TimeoutSeconds, -Notification)
pg_notify(+Connection, +Channel, +Payload)

pg_copy_from(+Connection, +CopySQL, +Data)
pg_copy_to(+Connection, +CopySQL, +Handler)

pg_backend_pid(+Connection, -PID)
pg_server_parameter(+Connection, +Name, -Value)
pg_last_command_tag(+Connection, -Tag)
pg_cancel(+Connection)
```

Connection options:

- `user/1`
- `password/1`
- `database/1`

`password/1` is optional when PostgreSQL authentication does not require it.

Encoding contract:

- the driver always negotiates `client_encoding=UTF8` during startup
- SQL text, text parameters, text/csv `COPY FROM STDIN` chunks, notices, error fields, and text row values are encoded and decoded as UTF-8
- sessions that cannot operate with `client_encoding=UTF8` are outside the supported contract

Query result values are one of:

- `ok`
- `ok(Tag)`
- `error(Fields)`
- `data(Columns, Rows)`

`pg_listen/3` accepts either `none` or a callable that will be invoked as `call(Handler, Notification)`.

For `pg_copy_from/3`, `Data` may be:

- a single text chunk, byte list, list of chunks, or `chunks(List)` for text/csv COPY
- `binary(TypeSpecs, Rows)` for binary COPY, where `TypeSpecs` are type names or OIDs and each row is a list (or `row(List)`) of field values

For text and csv COPY, each chunk is sent as one `CopyData` message and the driver finishes with `CopyDone`.

For binary COPY, the driver emits the PostgreSQL binary COPY header/trailer and encodes each row from `binary(TypeSpecs, Rows)` using the type layer.

`pg_copy_to/3` accepts either `none` or a callable that will be invoked as `call(Handler, Chunk)`, where `Chunk` is:

- `text(Text)` for text/csv COPY output
- `binary(Bytes)` for binary COPY output

After a successful `pg_copy_to/3`, inspect `pg_last_command_tag/2` if you need the final `COPY n` tag.

## Examples

Parameterized query:

```prolog
pg_query(Conn, "SELECT $1::int AS n, $2::text AS t", [1, "alpha"], Result).
```

Prepared statement:

```prolog
pg_prepare(Conn, test_stmt, "SELECT $1::int + 1 AS n", [int4]),
pg_execute(Conn, test_stmt, [41], Result).
```

LISTEN / NOTIFY:

```prolog
pg_listen(Conn, "events", none),
pg_wait_for_notification(Conn, 5.0, Notification).
```

COPY FROM STDIN:

```prolog
pg_copy_from(Conn,
             "COPY my_table (id, value) FROM STDIN WITH (FORMAT text)",
             chunks([
                 "1\thello\n",
                 "2\tworld\n"
             ])).
```

Binary COPY FROM STDIN:

```prolog
pg_copy_from(Conn,
             "COPY my_table (id, value) FROM STDIN WITH (FORMAT binary)",
             binary([int4, text], [
                 [1, "hello"],
                 [2, null]
             ])).
```

COPY TO STDOUT:

```prolog
pg_copy_to(Conn,
           "COPY my_table (id, value) TO STDOUT WITH (FORMAT text)",
           writeln).
```

## Notes

- simple-query and prepared-query paths recover to a usable connection after server-side errors
- multi-statement simple queries return the last result set or command status
- `pg_server_parameter/3` reads cached startup and status parameters already seen on the connection
- `pg_copy_from/3` supports `COPY ... FROM STDIN` in text, csv, and binary mode and recovers to a reusable connection after server-side COPY data errors
- `pg_copy_to/3` streams COPY output through a callback and drains back to a reusable connection even if the callback throws
- UTF-8 is an explicit wire-level contract: the startup message requests `client_encoding=UTF8`, matching the driver's text codecs

## Architecture

The driver is split into focused modules:

- `pg.pl` for the public API and session orchestration
- `pg_protocol.pl` for PostgreSQL wire protocol encoding and decoding
- `pg_types.pl` for type mapping and value conversion
- `pg_session.pl` for explicit session state and protocol-phase tracking

Current built-in decoding covers:

- `int4`
- `int8`
- `text`
- `varchar`
- `bool`
- `null`

## Authentication

Supported now:

- cleartext password
- `md5`
- SCRAM-SHA-256 (SASL), without channel binding

Not supported yet:

- SCRAM channel binding (`SCRAM-SHA-256-PLUS`), which requires SSL
- SSL

## Testing and Development

Environment variables used by the smoke and test commands:

- `PGHOST`
- `PGPORT`
- `PGUSER`
- `PGPASSWORD`
- `PGDATABASE`

Local test server options:

- `TEST_PG_AUTH` with `trust`, `md5`, or `scram-sha-256`
- `TEST_PG_PASSWORD` for `md5` and `scram-sha-256` modes

Commands:

```bash
make smoke
make test
make coverage
make test-local-pg
make test-local-pg-md5
make test-local-pg-scram
make profile-row-decode
make profile-row-decode-md5
make release
```

Examples:

```bash
make test-local-pg
make test-local-pg-md5
make test-local-pg-scram
TEST_PG_AUTH=md5 TEST_PG_PASSWORD=md5pass make test-local-pg
TEST_PG_AUTH=scram-sha-256 TEST_PG_PASSWORD=scrampass make test-local-pg
```

`make test-local-pg` starts a disposable local PostgreSQL instance. In `trust` mode the generated `.test-pg/env.sh` omits `PGPASSWORD`. In `md5` and `scram-sha-256` modes it exports `PGPASSWORD` so the same test command can authenticate without extra setup.

`make coverage` prints a summary and stores it in `coverage/summary.txt`.

`make profile-row-decode` runs `bench/pg_row_profile.pl` against a disposable local PostgreSQL instance and prints timing plus SWI-Prolog profiler output for large synthetic query result sets.

The profiler runner accepts environment overrides:

- `PG_PROFILE_ROWS` as a comma-separated list such as `10000,100000,300000`
- `PG_PROFILE_PROFILE_ROWS` for the row count used by the detailed profiler report
- `PG_PROFILE_PATHS` as `simple,params,prepared`
- `PG_PROFILE_SCENARIOS` as `narrow_ints,mixed_types,utf8_text,wide_text,wide_columns`
- `PG_PROFILE_TIME` as `cpu` or `wall`
- `PG_PROFILE_TOP` for the textual top-N report
- `PG_PROFILE_SAMPLE_RATE` for SWI-Prolog profiler sampling rate

`make release` creates a tarball in `dist/`.

## Repository Layout

- `pack.pl` contains SWI-Prolog pack metadata
- `prolog/postgresql_prolog/` contains the active driver modules
- `scripts/` contains local PostgreSQL test server helpers
- `test/` contains plunit tests and SQL fixtures
- `ROADMAP.md` contains planned architecture and implementation steps

## Roadmap

Planned next steps include:

- SSL support
- SCRAM channel binding (`SCRAM-SHA-256-PLUS`) once SSL is available
- broader COPY protocol coverage and more imported `epgsql_copy_SUITE` scenarios
- richer binary decoding paths
- broader built-in type coverage

## Contributing

Contributions are welcome.

Before sending changes:

- run `make test`
- if you change the local PostgreSQL test harness, also run `make test-local-pg`, `make test-local-pg-md5`, and `make test-local-pg-scram`
- keep changes aligned with the split between `pg.pl`, `pg_protocol.pl`, `pg_types.pl`, and `pg_session.pl`

## License

See `LICENSE`.