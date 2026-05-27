# postgresql-prolog

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?logo=postgresql&logoColor=white)](https://github.com/postgres/postgres)
[![SWI-Prolog](https://img.shields.io/badge/SWI--Prolog-E61B23?logo=prolog&logoColor=white)](https://github.com/SWI-Prolog/swipl-devel)

PostgreSQL driver prototype packaged as an SWI-Prolog pack.

See `ROADMAP.md` for the planned architecture steps.

## Current status

The active driver module is `pg`, provided by `library(postgresql_prolog/pg)`.

Implemented now:

- connect/disconnect
- simple query protocol
- explicit session state and protocol-phase tracking via `pg_session.pl`
- unified message-reading/recovery path to `ReadyForQuery`
- password and md5 authentication
- basic result decoding for `int4`, `int8`, `text`, `varchar`, `bool`, `null`
- prepared statements / parameterized queries
- recovery after simple-query and extended-query protocol errors
- LISTEN/NOTIFY
- `COPY FROM STDIN` for text/csv input via `pg_copy.pl`
- metadata helpers for backend PID, server parameters, and last command tag

Not implemented yet:

- SCRAM/SASL authentication
- SSL
- `COPY TO STDOUT`
- binary COPY
- cancel API
- binary result formats for extended query mode

## Requirements

- SWI-Prolog
- running PostgreSQL server

## Usage

Install or attach the pack and load the driver:

```prolog
:- use_module(library(postgresql_prolog/pg)).
```

For local development from a checkout, add the repository `prolog/` directory to the library search path before loading the module:

```prolog
:- asserta(user:file_search_path(library, 'prolog')).
:- use_module(library(postgresql_prolog/pg)).
```

Connect:

```prolog
pg_connect(+HostPort, -Connection, +Options)
```

Where:

- `HostPort` is `Host:Port`
- `Options` may contain `user/1`, `password/1`, `database/1`
- `password/1` is optional when PostgreSQL auth does not require it

Run a query:

```prolog
pg_query(+Connection, +SQL, -Result)
```

`Result` is one of:

- `ok`
- `ok(Tag)`
- `error(Fields)`
- `data(Columns, Rows)`

Listen for notifications:

```prolog
pg_listen(+Connection, +Channel, +Handler)
pg_wait_for_notification(+Connection, +TimeoutSeconds, -Notification)
pg_notify(+Connection, +Channel, +Payload)
```

`Handler` is either `none` or a callable that will be invoked as `call(Handler, Notification)`.

Inspect connection metadata:

```prolog
pg_backend_pid(+Connection, -PID)
pg_server_parameter(+Connection, +Name, -Value)
pg_last_command_tag(+Connection, -Tag)
```

Send rows with `COPY FROM STDIN`:

```prolog
pg_copy_from(+Connection, +CopySQL, +Data)
```

`Data` may be a single text chunk, a byte list, a list of chunks, or `chunks(List)`.
For text/csv COPY, each chunk is sent as one `CopyData` message and the driver finishes with `CopyDone`.

Current notes:

- simple-query and prepared-query paths recover to a usable connection after server-side errors
- multi-statement simple queries return the last result set / command status
- `pg_server_parameter/3` reads cached startup and status parameters already seen on the connection
- `pg_copy_from/3` currently supports `COPY ... FROM STDIN` in text/csv mode and now recovers to a reusable connection after server-side COPY data errors; binary COPY is planned next

## Example

```prolog
:- use_module(library(postgresql_prolog/pg)).

demo :-
    pg_connect('127.0.0.1':5432, Conn,
        [ user("postgres"),
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

## Test and development

Environment variables used by the test and smoke commands:

- `PGHOST`
- `PGPORT`
- `PGUSER`
- `PGPASSWORD`
- `PGDATABASE`
- `TEST_PG_AUTH` for the local test server (`trust` by default, or `md5`)
- `TEST_PG_PASSWORD` for the local test server password when `TEST_PG_AUTH=md5`

Commands:

```bash
make smoke
make test
make coverage
make test-local-pg
make test-local-pg-md5
make release
```

Examples:

```bash
make test-local-pg
make test-local-pg-md5
TEST_PG_AUTH=md5 TEST_PG_PASSWORD=md5pass make test-local-pg
```

`make test-local-pg` starts a disposable local PostgreSQL instance. In `trust` mode the generated `.test-pg/env.sh` omits `PGPASSWORD`; in `md5` mode it exports `PGPASSWORD` so the same test command can authenticate without extra setup.

`make coverage` prints a summary and stores it in `coverage/summary.txt`.

`make release` creates a tarball in `dist/`.

## Repository layout

- `pack.pl` contains SWI-Prolog pack metadata
- `prolog/postgresql_prolog/` contains the active driver modules
- `test/` contains plunit tests and SQL fixtures