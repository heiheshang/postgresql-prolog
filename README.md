```
   ___   ___   ___   ___   ___   ___   ___   ___ 
  | _ \ / _ \ / __| / __| / _ \ |_ _| / __| / __|
  |  _/| (_) |\__ \ \__ \| (_) | | |  \__ \ \__ \
  |_|   \___/ |___/ |___/ \___/ |___| |___/ |___|
```

# 🐘 PostgreSQL Driver for SWI-Prolog

> A native PostgreSQL wire-protocol driver for SWI-Prolog — simple queries, prepared statements, LISTEN/NOTIFY, COPY streaming, and three authentication methods, all in pure Prolog.

[![CI](https://github.com/heiheshang/postgresql-prolog/actions/workflows/test.yml/badge.svg)](https://github.com/heiheshang/postgresql-prolog/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/heiheshang/postgresql-prolog?style=flat-square)](https://github.com/heiheshang/postgresql-prolog/releases)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?logo=postgresql&logoColor=white&style=flat-square)](https://github.com/postgres/postgres)
[![SWI-Prolog](https://img.shields.io/badge/SWI--Prolog-E61B23?logo=prolog&logoColor=white&style=flat-square)](https://github.com/SWI-Prolog/swipl-devel)
[![License](https://img.shields.io/badge/license-BSD--2--Clause-blue?style=flat-square)](LICENSE)

---

## 📑 Contents

- [💡 What is PostgreSQL-Prolog?](#-what-is-postgresql-prolog)
- [⚡ Why Prolog + PostgreSQL?](#-why-prolog--postgresql)
- [🚀 Quick Start](#-quick-start)
- [📋 API Overview](#-api-overview)
- [📖 Examples](#-examples)
- [🏗️ Architecture](#️-architecture)
- [🔐 Authentication](#-authentication)
- [🧪 Testing and Development](#-testing-and-development)
- [📁 Repository Layout](#-repository-layout)
- [🗺️ Roadmap](#️-roadmap)
- [🤝 Contributing](#-contributing)
- [📜 License](#-license)

---

## 💡 What is PostgreSQL-Prolog?

**The problem.** SWI-Prolog needs to talk to PostgreSQL, but ODBC adds C dependencies, middleware latency, and opaque error handling. You want direct, native access to the wire protocol — from connection to query to COPY streaming — with Prolog-friendly results you can pattern-match on.

**The fix.** `postgresql-prolog` is a pure-Prolog driver that speaks the PostgreSQL wire protocol directly over TCP sockets. No C extensions. No ODBC. No middleware. Just a socket and Prolog.

**What you get:**
- Connect/disconnect with cleartext, `md5`, and SCRAM-SHA-256 authentication
- Simple queries, parameterized queries, and prepared statements
- LISTEN/NOTIFY for async event handling
- `COPY FROM STDIN` in text, csv, and binary mode
- Streaming `COPY TO STDOUT` via callback
- Explicit session state tracking with recovery after protocol errors
- Connection metadata: backend PID, server parameters, command tags
- Cancel running queries via `pg_cancel/1`

> 💡 **Key differentiator — pure Prolog.** No C extensions means no compilation headaches, no FFI bugs, and full visibility into every byte on the wire. The driver is self-contained and debuggable with standard Prolog tools.

---

## ⚡ Why Prolog + PostgreSQL?

SWI-Prolog is excellent at logical reasoning and symbolic computation. But production applications need persistent storage, concurrent access, and integration with existing PostgreSQL databases.

`postgresql-prolog` bridges that gap:
- **Direct wire protocol** — speaks PostgreSQL v3.0 protocol natively; no intermediate layers
- **Prolog-friendly results** — query results as `data(Columns, Rows)` terms you can unify and pattern-match
- **Explicit state machine** — session phases (`ready`, `simple_query`, `extended_query`, `copy_in`, `copy_out`, `failed_until_sync`) are tracked and recoverable
- **UTF-8 by contract** — the driver always negotiates `client_encoding=UTF8`; all text is encoded and decoded as UTF-8

---

## 🚀 Quick Start

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

Or try the runnable example:

```bash
swipl -q -f examples/simple.pl -g simple -t halt
```

---

## 📋 API Overview

Main predicates:

| Predicate | Description |
|---|---|
| `pg_connect(+HostPort, -Connection, +Options)` | Open a connection |
| `pg_disconnect(+Connection)` | Close a connection |
| `pg_query(+Connection, +SQL, -Result)` | Simple query |
| `pg_query(+Connection, +SQL, +Params, -Result)` | Parameterized query |
| `pg_prepare(+Connection, +Name, +SQL, +ParamTypes)` | Create a prepared statement |
| `pg_execute(+Connection, +Name, +Params, -Result)` | Execute a prepared statement |
| `pg_listen(+Connection, +Channel, +Handler)` | Listen for notifications |
| `pg_wait_for_notification(+Connection, +Timeout, -Notification)` | Block until notification |
| `pg_notify(+Connection, +Channel, +Payload)` | Send a notification |
| `pg_copy_from(+Connection, +CopySQL, +Data)` | COPY FROM STDIN |
| `pg_copy_to(+Connection, +CopySQL, +Handler)` | Streaming COPY TO STDOUT |
| `pg_backend_pid(+Connection, -PID)` | Get backend process ID |
| `pg_server_parameter(+Connection, +Name, -Value)` | Read server parameter |
| `pg_last_command_tag(+Connection, -Tag)` | Last command tag or status |
| `pg_cancel(+Connection)` | Cancel running query |

**Connection options:** `user/1`, `password/1`, `database/1`. `password/1` is optional when PostgreSQL authentication does not require it.

**Query result values** are one of: `ok`, `ok(Tag)`, `error(Fields)`, `data(Columns, Rows)`.

---

## 📖 Examples

### Parameterized query

```prolog
pg_query(Conn, "SELECT $1::int AS n, $2::text AS t", [1, "alpha"], Result).
```

### Prepared statement

```prolog
pg_prepare(Conn, test_stmt, "SELECT $1::int + 1 AS n", [int4]),
pg_execute(Conn, test_stmt, [41], Result).
```

### LISTEN / NOTIFY

```prolog
pg_listen(Conn, "events", none),
pg_wait_for_notification(Conn, 5.0, Notification).
```

### COPY FROM STDIN (text)

```prolog
pg_copy_from(Conn,
             "COPY my_table (id, value) FROM STDIN WITH (FORMAT text)",
             chunks([
                 "1\thello\n",
                 "2\tworld\n"
             ])).
```

### Binary COPY FROM STDIN

```prolog
pg_copy_from(Conn,
             "COPY my_table (id, value) FROM STDIN WITH (FORMAT binary)",
             binary([int4, text], [
                 [1, "hello"],
                 [2, null]
             ])).
```

### COPY TO STDOUT (streaming)

```prolog
pg_copy_to(Conn,
           "COPY my_table (id, value) TO STDOUT WITH (FORMAT text)",
           writeln).
```

---

## 🏗️ Architecture

The driver is split into focused modules — each layer handles one concern:

```
┌──────────────────────────────────────────────┐
│  pg.pl          Public API & orchestration   │
├──────────────────────────────────────────────┤
│  pg_session.pl  Session state & phases       │
├──────────────────────────────────────────────┤
│  pg_protocol.pl Wire encoding/decoding (DCG) │
├──────────────┬───────────────────────────────┤
│  pg_types.pl │  pg_auth.pl  │ pg_scram.pl   │
│  Type map    │  Auth flow   │  SCRAM crypto │
├──────────────┴───────────────┴───────────────┤
│  pg_prepared.pl  │  pg_copy.pl  │ pg_async.pl│
│  Extended query   │  COPY I/O    │  NOTIFY    │
└──────────────────┴──────────────┴────────────┘
```

**Built-in type decoding** covers: `int4`, `int8`, `text`, `varchar`, `bool`, `null`.

**Encoding contract:** the driver always negotiates `client_encoding=UTF8` during startup. SQL text, text parameters, text/csv COPY chunks, notices, error fields, and text row values are encoded and decoded as UTF-8.

---

## 🔐 Authentication

| Method | Status |
|---|---|
| cleartext password | ✅ Supported |
| `md5` | ✅ Supported |
| SCRAM-SHA-256 (SASL) | ✅ Supported |
| `SCRAM-SHA-256-PLUS` (channel binding) | ❌ Requires SSL |
| SSL | ❌ Not yet |

SCRAM-SHA-256 is implemented via a pure `pg_scram.pl` layer (PBKDF2-HMAC-SHA256, client/server proof, server-signature verification), validated against RFC 7677 test vectors.

---

## 🧪 Testing and Development

### Environment variables

| Variable | Purpose |
|---|---|
| `PGHOST` | PostgreSQL host |
| `PGPORT` | PostgreSQL port |
| `PGUSER` | PostgreSQL user |
| `PGPASSWORD` | PostgreSQL password |
| `PGDATABASE` | PostgreSQL database |
| `TEST_PG_AUTH` | Auth mode: `trust`, `md5`, or `scram-sha-256` |
| `TEST_PG_PASSWORD` | Password for `md5` and `scram-sha-256` modes |

### Commands

```bash
make smoke               # Quick connectivity check
make test                # Full test suite against configured PG
make coverage            # Test coverage report → coverage/summary.txt
make test-local-pg       # Full suite on disposable local PG (trust)
make test-local-pg-md5   # Same, with md5 auth
make test-local-pg-scram # Same, with SCRAM-SHA-256 auth
make profile-row-decode  # Row decoding benchmark + profiler
make release             # Create tarball in dist/
```

### Local test server

`make test-local-pg` starts a disposable local PostgreSQL instance. In `trust` mode the generated `.test-pg/env.sh` omits `PGPASSWORD`. In `md5` and `scram-sha-256` modes it exports `PGPASSWORD` so the same test command can authenticate without extra setup.

Override auth mode:

```bash
TEST_PG_AUTH=md5 TEST_PG_PASSWORD=md5pass make test-local-pg
TEST_PG_AUTH=scram-sha-256 TEST_PG_PASSWORD=scrampass make test-local-pg
```

### Row decoding profiler

```bash
make profile-row-decode
make profile-row-decode-md5
```

Accepts environment overrides:

| Variable | Example |
|---|---|
| `PG_PROFILE_ROWS` | `10000,100000,300000` |
| `PG_PROFILE_PATHS` | `simple,params,prepared` |
| `PG_PROFILE_SCENARIOS` | `narrow_ints,mixed_types,utf8_text` |
| `PG_PROFILE_TIME` | `cpu` or `wall` |

---

## 📁 Repository Layout

```
├── pack.pl                     SWI-Prolog pack metadata
├── prolog/postgresql_prolog/   Active driver modules
│   ├── pg.pl                   Public API & orchestration
│   ├── pg_session.pl           Session state & phases
│   ├── pg_protocol.pl          Wire protocol (DCG)
│   ├── pg_types.pl             Type mapping & conversion
│   ├── pg_auth.pl              Authentication flow
│   ├── pg_scram.pl             SCRAM-SHA-256 crypto
│   ├── pg_prepared.pl          Extended query protocol
│   ├── pg_copy.pl              COPY I/O
│   └── pg_async.pl             Async NOTIFY handling
├── test/                       plunit tests + SQL fixtures
├── scripts/                    Local PG test server helpers
├── bench/                      Row decoding profiler
├── examples/                   Runnable examples
├── ROADMAP.md                  Planned architecture steps
└── CHANGELOG.md                Release history
```

---

## 🗺️ Roadmap

**Done:**
- connect / disconnect
- simple query protocol
- prepared statements and parameterized queries
- explicit session state and protocol-phase tracking via `pg_session.pl`
- unified message-reading and recovery to `ReadyForQuery`
- cleartext password, `md5`, and SCRAM-SHA-256 (SASL) authentication
- basic result decoding: `int4`, `int8`, `text`, `varchar`, `bool`, `null`
- LISTEN / NOTIFY
- `COPY FROM STDIN` for text, csv, and binary input via `pg_copy.pl`
- streaming `COPY TO STDOUT` via callback-driven `pg_copy_to/3`
- metadata helpers: backend PID, server parameters, last command tag
- cancel API via `pg_cancel/1`
- recovery after simple-query, extended-query, and server-side COPY errors

**Planned:**
- SSL support
- SCRAM channel binding (`SCRAM-SHA-256-PLUS`) once SSL is available
- broader COPY protocol coverage from `epgsql_copy_SUITE`
- richer binary decoding paths
- broader built-in type coverage (arrays, json/jsonb, uuid, date/time)

> See `ROADMAP.md` for detailed architecture steps.

---

## 🤝 Contributing

Contributions are welcome. Before sending changes:

- run `make test`
- if you change the local PostgreSQL test harness, also run `make test-local-pg`, `make test-local-pg-md5`, and `make test-local-pg-scram`
- keep changes aligned with the module split (see [Architecture](#️-architecture))

---

## 📜 License

BSD 2-Clause — see [LICENSE](LICENSE).
