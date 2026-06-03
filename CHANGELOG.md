# Changelog

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
