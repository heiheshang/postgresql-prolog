# PostgreSQL Prolog Driver Roadmap

## Near term

1. `pg_session.pl`

- Status: done
- Introduced explicit session state and protocol phases:
  - `ready`
  - `simple_query`
  - `extended_query`
  - `copy_in`
  - `copy_out`
  - `failed_until_sync`
- Centralized backend PID, cancel secret, server parameters, async handlers, and last command tag.
- Added one message-reading/recovery path that drains correctly to `ReadyForQuery`.

2. Extended-query recovery

- Status: done
- Strengthened `pg_prepared.pl` and session orchestration around parse/bind/execute errors.
- Made `sync_required` an explicit internal state in the session layer after protocol failures.
- Added tests for parse/bind/execute failure and successful reuse of the connection after recovery.

3. `pg_copy.pl`

- Status: partial
- Added a dedicated `pg_copy.pl` layer and wired `pg_copy_from/3` through the public API.
- Added protocol support for `CopyData`, `CopyDone`, `CopyFail`, and parsing `CopyInResponse`.
- Implemented `COPY FROM STDIN` for text/csv and binary input.
- Implemented streaming `COPY TO STDOUT` via callback-driven `pg_copy_to/3`.
- Added passing tests for:
  - text `COPY FROM STDIN`
  - csv `COPY FROM STDIN`
  - binary `COPY FROM STDIN`
  - text `COPY TO STDOUT`
  - startup/error path for `pg_copy_from/3`
  - connection reuse after server-side COPY data error
  - connection reuse after `COPY TO STDOUT` callback failure
- Remaining inside this layer:
  - port more scenarios from `epgsql_copy_SUITE`

## Next layer

4. `pg_async.pl` expansion

- Status: done
- Keep notice/notify handling in the async layer.
- Stable queue/handler behavior now exists through the session layer and `pg_async.pl`.
- Backend PID access is now exposed through session metadata helpers.
- Added `cancel/1` via a temporary connection using backend PID and secret.

5. Session metadata API

- Status: done
- Added public helpers for:
  - backend PID
  - server parameter lookup
  - last command tag or status

6. Type system v2

- Status: pending
- Extend `pg_types.pl` with a cleaner registry for custom decoders/encoders.
- Add the next useful types: arrays, json/jsonb, uuid, and date/time families.
- Prepare for binary result formats in extended query mode.

## Testing priorities

Done:

1. Extended-query error recovery
2. `RETURNING` on `DELETE`
3. Parameter/status cache behavior
4. Backend PID API
5. Multi-statement simple query behavior

Remaining:

6. deeper COPY recovery and protocol suite

## Authentication

7. SCRAM-SHA-256 (SASL)

- Status: done
- Added a pure `pg_scram.pl` layer (PBKDF2-HMAC-SHA256, client/server proof, signature verification), validated against the RFC 7677 test vectors.
- Extended `pg_protocol.pl` to parse the SASL mechanism list and fixed `sasl_initial_response/3` to carry the full client-first message.
- Drove the SASL exchange and server-signature verification from `pg_auth.pl`.
- Added a `scram-sha-256` mode to the local test harness (`make test-local-pg-scram`); the full suite passes over a real SCRAM connection.
- Remaining: SCRAM channel binding (`SCRAM-SHA-256-PLUS`), which depends on SSL.

## Summary

The shortest practical path is:

1. port more COPY scenarios and deepen the COPY protocol suite
2. expand the type system
3. add SSL, then SCRAM channel binding (`SCRAM-SHA-256-PLUS`)
