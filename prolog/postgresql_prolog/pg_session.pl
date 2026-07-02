:- module(pg_session, [
    pg_session_open/1,
    pg_session_open/3,
    pg_session_close/1,
    pg_session_new/2,
    pg_session_new/4,
    pg_session_get/2,
    pg_session_set/2,
    pg_session_set_phase/2,
    pg_session_mark_sync_required/1,
    pg_session_clear_sync_required/1,
    pg_session_set_backend_key/3,
    pg_session_add_parameter/2,
    pg_session_set_tx_status/2,
    pg_session_set_notice_handler/2,
    pg_session_set_notification_handler/2,
    pg_session_push_notification/2,
    pg_session_pop_notification/2,
    pg_session_store_prepared_statement/3,
    pg_session_prepared_statement/3,
    pg_session_clear_prepared_statements/1,
    pg_session_set_last_command_tag/2,
    pg_session_backend_pid/2,
    pg_session_server_parameter/3,
    pg_session_last_command_tag/2,
    pg_session_prepare_command/2,
    pg_session_read_until_ready/2,
    session_push_notification/3
]).

:- use_module(library(lists)).
:- use_module(library(error)).
:- use_module(library(postgresql_prolog/pg_async)).
:- use_module(library(postgresql_prolog/pg_protocol)).

:- thread_local
    session_state/2.

/** <module> PostgreSQL session state tracking.

Internal session layer for the PostgreSQL driver.
This module stores per-connection state such as protocol phase, transaction
status, backend key data, server parameters, handlers, queued notifications,
and prepared-statement metadata, and it centralizes draining to
`ReadyForQuery`.

It supports the public API in `pg.pl` but is not intended for direct
application use.
*/

pg_session_open(Stream) :-
    pg_session_open(Stream, '127.0.0.1', 5432).

pg_session_open(Stream, Host, Port) :-
    pg_session_new(Stream, Host, Port, Session),
    pg_session_set(Stream, Session).

pg_session_close(Stream) :-
    retractall(session_state(Stream, _)).

pg_session_new(Stream, Session) :-
    pg_session_new(Stream, '127.0.0.1', 5432, Session).

pg_session_new(_Stream, Host, Port, session{
    host: Host,
    port: Port,
    phase: ready,
    backend_pid: 0,
    cancel_secret: 0,
    server_params: [],
    tx_status: idle,
    notice_handler: none,
    notification_handler: none,
    pending_notifications: [],
    prepared_statements: [],
    last_command_tag: none,
    sync_required: false
}).

pg_session_get(Stream, Session) :-
    session_state(Stream, Session),
    !.
pg_session_get(Stream, _) :-
    throw(error(existence_error(pg_session, Stream), _)).

pg_session_set(Stream, Session) :-
    retractall(session_state(Stream, _)),
    assertz(session_state(Stream, Session)).

% Stream-keyed mutators (operation boundary).
% Each one reads the current session record from the thread-local store,
% applies a pure `session_*` State0->State1 transition, and writes it back.

pg_session_set_phase(Stream, Phase) :-
    pg_session_get(Stream, Session0),
    session_set_phase(Session0, Phase, Session1),
    pg_session_set(Stream, Session1).

pg_session_mark_sync_required(Stream) :-
    pg_session_get(Stream, Session0),
    session_mark_sync_required(Session0, Session1),
    pg_session_set(Stream, Session1).

pg_session_clear_sync_required(Stream) :-
    pg_session_get(Stream, Session0),
    session_clear_sync_required(Session0, Session1),
    pg_session_set(Stream, Session1).

pg_session_set_backend_key(Stream, PID, Secret) :-
    pg_session_get(Stream, Session0),
    session_set_backend_key(Session0, PID, Secret, Session1),
    pg_session_set(Stream, Session1).

pg_session_add_parameter(Stream, KeyValue) :-
    pg_session_get(Stream, Session0),
    session_add_parameter(Session0, KeyValue, Session1),
    pg_session_set(Stream, Session1).

pg_session_set_tx_status(Stream, TxStatus) :-
    pg_session_get(Stream, Session0),
    session_set_tx_status(Session0, TxStatus, Session1),
    pg_session_set(Stream, Session1).

pg_session_set_notice_handler(Stream, Pred) :-
    pg_session_get(Stream, Session0),
    session_set_notice_handler(Session0, Pred, Session1),
    pg_session_set(Stream, Session1).

pg_session_set_notification_handler(Stream, Pred) :-
    pg_session_get(Stream, Session0),
    session_set_notification_handler(Session0, Pred, Session1),
    pg_session_set(Stream, Session1).

pg_session_push_notification(Stream, Notification) :-
    pg_session_get(Stream, Session0),
    session_push_notification(Session0, Notification, Session1),
    pg_session_set(Stream, Session1).

pg_session_pop_notification(Stream, Notification) :-
    pg_session_get(Stream, Session0),
    session_pop_notification(Session0, Notification, Session1),
    pg_session_set(Stream, Session1).

pg_session_store_prepared_statement(Stream, Name, ParamOids) :-
    pg_session_get(Stream, Session0),
    session_store_prepared_statement(Session0, Name, ParamOids, Session1),
    pg_session_set(Stream, Session1).

pg_session_prepared_statement(Stream, Name, ParamOids) :-
    pg_session_get(Stream, Session),
    session_prepared_statement(Session, Name, ParamOids).

pg_session_clear_prepared_statements(Stream) :-
    (   session_state(Stream, Session0)
    ->  session_clear_prepared_statements(Session0, Session1),
        pg_session_set(Stream, Session1)
    ;   true
    ).

pg_session_set_last_command_tag(Stream, Tag) :-
    pg_session_get(Stream, Session0),
    session_set_last_command_tag(Session0, Tag, Session1),
    pg_session_set(Stream, Session1).

pg_session_backend_pid(Stream, PID) :-
    pg_session_get(Stream, Session),
    PID = Session.backend_pid.

pg_session_server_parameter(Stream, Name, Value) :-
    pg_session_get(Stream, Session),
    normalize_param_name(Name, Key),
    memberchk(Key-Value, Session.server_params).

pg_session_last_command_tag(Stream, Tag) :-
    pg_session_get(Stream, Session),
    Tag = Session.last_command_tag.

% Pure session transitions (no store access). These express each state change
% as an explicit State0->State1 step, keeping the transition logic testable
% without a socket or the thread-local store.

session_set_phase(Session0, Phase, Session1) :-
    Session1 = Session0.put(phase, Phase).

session_mark_sync_required(Session0, Session1) :-
    Session1 = Session0.put(_{phase: failed_until_sync, sync_required: true}).

session_clear_sync_required(Session0, Session1) :-
    Session1 = Session0.put(sync_required, false).

session_set_backend_key(Session0, PID, Secret, Session1) :-
    Session1 = Session0.put(_{backend_pid: PID, cancel_secret: Secret}).

session_add_parameter(Session0, Key-Value, Session1) :-
    put_assoc_list(Key, Value, Session0.server_params, Params),
    Session1 = Session0.put(server_params, Params).

session_set_tx_status(Session0, TxStatus, Session1) :-
    Session1 = Session0.put(tx_status, TxStatus).

session_set_notice_handler(Session0, Pred, Session1) :-
    Session1 = Session0.put(notice_handler, Pred).

session_set_notification_handler(Session0, Pred, Session1) :-
    Session1 = Session0.put(notification_handler, Pred).

session_push_notification(Session0, Notification, Session1) :-
    append(Session0.pending_notifications, [Notification], Pending),
    Session1 = Session0.put(pending_notifications, Pending).

session_pop_notification(Session0, Notification, Session1) :-
    Session0.pending_notifications = [Notification|Rest],
    Session1 = Session0.put(pending_notifications, Rest).

session_store_prepared_statement(Session0, Name, ParamOids, Session1) :-
    put_assoc_list(Name, ParamOids, Session0.prepared_statements, Prepared),
    Session1 = Session0.put(prepared_statements, Prepared).

session_prepared_statement(Session, Name, ParamOids) :-
    memberchk(Name-ParamOids, Session.prepared_statements).

session_clear_prepared_statements(Session0, Session1) :-
    Session1 = Session0.put(prepared_statements, []).

session_set_last_command_tag(Session0, Tag, Session1) :-
    Session1 = Session0.put(last_command_tag, Tag).

pg_session_prepare_command(Stream, Phase) :-
    pg_session_get(Stream, Session),
    (   Session.sync_required == true
    ->  throw(error(protocol_error(sync_required(Phase)), _))
    ;   true
    ),
    (   Session.phase == ready
    ->  pg_session_set_phase(Stream, Phase)
    ;   throw(error(protocol_error(busy_phase(Session.phase, Phase)), _))
    ).

pg_session_read_until_ready(Stream, Messages) :-
    pg_session_get(Stream, Session0),
    read_until_ready(Stream, Session0, Session, [], RevMessages),
    pg_session_set(Stream, Session),
    reverse(RevMessages, Messages).

% The session record is threaded explicitly through the read loop as
% Session0->Session and persisted to the store exactly once, instead of
% mutating the thread-local store on every backend message.
read_until_ready(Stream, Session0, Session, Acc, Messages) :-
    read_message(Stream, Message),
    Message = Type-Bytes,
    process_backend_message(Stream, Type, Bytes, Session0, Session1, Acc, NextAcc, Done),
    (   Done == true
    ->  Session = Session1,
        Messages = NextAcc
    ;   read_until_ready(Stream, Session1, Session, NextAcc, Messages)
    ).

process_backend_message(_Stream, parameter, Bytes, Session0, Session1, Acc, Acc, false) :-
    !,
    parse_parameter_status(Bytes, KeyValue),
    session_add_parameter(Session0, KeyValue, Session1).
process_backend_message(_Stream, backend_key, Bytes, Session0, Session1, Acc, Acc, false) :-
    !,
    parse_backend_key(Bytes, PID, Secret),
    session_set_backend_key(Session0, PID, Secret, Session1).
process_backend_message(Stream, notice, Bytes, Session0, Session1, Acc, Acc, false) :-
    !,
    pg_async:process_async_message(Stream, notice-Bytes, Session0, Session1).
process_backend_message(Stream, notify, Bytes, Session0, Session1, Acc, Acc, false) :-
    !,
    pg_async:process_async_message(Stream, notify-Bytes, Session0, Session1).
process_backend_message(_Stream, cmd_complete, Bytes, Session0, Session1, Acc, [cmd_complete-Bytes|Acc], false) :-
    !,
    parse_command_complete(Bytes, Tag),
    session_set_last_command_tag(Session0, Tag, Session1).
process_backend_message(_Stream, error, Bytes, Session0, Session1, Acc, [error-Bytes|Acc], false) :-
    !,
    (   Session0.phase == extended_query
    ->  session_mark_sync_required(Session0, Session1)
    ;   Session1 = Session0
    ).
process_backend_message(_Stream, ready, Bytes, Session0, Session, Acc, Acc, true) :-
    !,
    parse_ready_for_query(Bytes, TxStatus),
    session_set_tx_status(Session0, TxStatus, Session1),
    session_set_phase(Session1, ready, Session2),
    session_clear_sync_required(Session2, Session).
process_backend_message(_Stream, Type, Bytes, Session, Session, Acc, [Type-Bytes|Acc], false).

put_assoc_list(Key, Value, Pairs0, [Key-Value|Pairs]) :-
    remove_assoc_list(Key, Pairs0, Pairs).

remove_assoc_list(_, [], []).
remove_assoc_list(Key, [Key-_|Pairs], Rest) :-
    !,
    remove_assoc_list(Key, Pairs, Rest).
remove_assoc_list(Key, [Pair|Pairs], [Pair|Rest]) :-
    remove_assoc_list(Key, Pairs, Rest).

normalize_param_name(Name, Key) :-
    (   string(Name)
    ->  Key = Name
    ;   atom(Name)
    ->  atom_string(Name, Key)
    ;   type_error(text, Name)
    ).
