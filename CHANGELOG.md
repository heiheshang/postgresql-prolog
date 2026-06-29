# Changelog

## Unreleased

## 0.2.1

Patch release that moves prepared statements and session message handling
closer to explicit per-connection state without changing the public API.

Highlights:

- move prepared statements into the per-session state container
- thread session state explicitly through the backend read loop
- reduce disconnect cleanup to a single session-state teardown path
- keep async notice/notify routing and COPY side-message handling compatible
- preserve the existing public predicate signatures and local test coverage

## 0.2.0

Feature release that expands COPY support, adds cancellation and profiling
tools, and improves package-level documentation.

Highlights:

- add `pg_cancel/1` and centralize row decoding around the active driver layers
- add binary `COPY FROM STDIN` with typed row input via `binary(TypeSpecs, Rows)`
- add streaming `pg_copy_to/3` for `COPY TO STDOUT` with callback-delivered chunks
- add a row-decoding profiling harness and preserve the measured optimizations in the driver
- add package/module documentation plus a runnable `examples/simple.pl` example
- recover cleanly after `COPY TO STDOUT` callback failures and binary COPY server-side errors
- add byte-level COPY framing tests plus local PostgreSQL coverage for binary COPY and streaming COPY-out

## 0.1.2

Patch release that tightens protocol handling and improves release confidence.

Highlights:

- fix the UTF-8 startup encoding contract
- fix simple-query result selection for multi-statement responses
- fix `COPY FROM STDIN` recovery after negotiation and server-side failures
- fix connection cleanup and transaction-state checks after errors
- refactor `pg_protocol.pl` to express wire encoding/decoding via DCG-based binary helpers
- add focused byte-level protocol tests alongside the existing integration suite

## 0.1.1

Patch release that adds explicit `library(apply)` imports in `pg.pl` and
`pg_prepared.pl` so `maplist/3` remains available in packaged builds.

## 0.1.0

Initial public release of the SWI-Prolog PostgreSQL driver pack.

Highlights:

- connection lifecycle with simple queries
- prepared statements and parameterized queries
- cleartext password and `md5` authentication
- LISTEN / NOTIFY support
- `COPY FROM STDIN` for text and csv input
- session-state tracking and recovery after protocol errors
- local PostgreSQL test harness with both `trust` and `md5` modes
