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
    pg_session_set_last_command_tag/2,
    pg_session_backend_pid/2,
    pg_session_server_parameter/3,
    pg_session_last_command_tag/2,
    pg_session_prepare_command/2,
    pg_session_read_until_ready/2
]).

:- use_module(library(postgresql_prolog/pg_async)).
:- use_module(library(postgresql_prolog/pg_protocol)).

:- thread_local
    session_state/2.

/** <module> PostgreSQL session state tracking.

Internal session layer for the PostgreSQL driver.
This module stores per-connection state such as protocol phase, transaction
status, backend key data, server parameters, handlers, and queued
notifications, and it centralizes draining to `ReadyForQuery`.

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

pg_session_set_phase(Stream, Phase) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream, Session.put(phase, Phase)).

pg_session_mark_sync_required(Stream) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream,
                   Session.put(_{phase: failed_until_sync, sync_required: true})).

pg_session_clear_sync_required(Stream) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream, Session.put(sync_required, false)).

pg_session_set_backend_key(Stream, PID, Secret) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream,
                   Session.put(_{backend_pid: PID, cancel_secret: Secret})).

pg_session_add_parameter(Stream, Key-Value) :-
    pg_session_get(Stream, Session),
    put_assoc_list(Key, Value, Session.server_params, Params),
    pg_session_set(Stream, Session.put(server_params, Params)).

pg_session_set_tx_status(Stream, TxStatus) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream, Session.put(tx_status, TxStatus)).

pg_session_set_notice_handler(Stream, Pred) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream, Session.put(notice_handler, Pred)).

pg_session_set_notification_handler(Stream, Pred) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream, Session.put(notification_handler, Pred)).

pg_session_push_notification(Stream, Notification) :-
    pg_session_get(Stream, Session),
    append(Session.pending_notifications, [Notification], Pending),
    pg_session_set(Stream,
                   Session.put(pending_notifications,
                               Pending)).

pg_session_pop_notification(Stream, Notification) :-
    pg_session_get(Stream, Session0),
    Session0.pending_notifications = [Notification|Rest],
    pg_session_set(Stream, Session0.put(pending_notifications, Rest)).

pg_session_set_last_command_tag(Stream, Tag) :-
    pg_session_get(Stream, Session),
    pg_session_set(Stream, Session.put(last_command_tag, Tag)).

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
    read_until_ready(Stream, [], RevMessages),
    reverse(RevMessages, Messages).

read_until_ready(Stream, Acc, Messages) :-
    read_message(Stream, Message),
    Message = Type-Bytes,
    process_backend_message(Stream, Type, Bytes, Acc, NextAcc, Done),
    (   Done == true
    ->  Messages = NextAcc
    ;   read_until_ready(Stream, NextAcc, Messages)
    ).

process_backend_message(Stream, parameter, Bytes, Acc, Acc, false) :-
    !,
    parse_parameter_status(Bytes, KeyValue),
    pg_session_add_parameter(Stream, KeyValue).
process_backend_message(Stream, backend_key, Bytes, Acc, Acc, false) :-
    !,
    parse_backend_key(Bytes, PID, Secret),
    pg_session_set_backend_key(Stream, PID, Secret).
process_backend_message(Stream, notice, Bytes, Acc, Acc, false) :-
    !,
    pg_async:pg_process_async_message(Stream, notice-Bytes).
process_backend_message(Stream, notify, Bytes, Acc, Acc, false) :-
    !,
    pg_async:pg_process_async_message(Stream, notify-Bytes).
process_backend_message(Stream, cmd_complete, Bytes, Acc, [cmd_complete-Bytes|Acc], false) :-
    !,
    parse_command_complete(Bytes, Tag),
    pg_session_set_last_command_tag(Stream, Tag).
process_backend_message(Stream, error, Bytes, Acc, [error-Bytes|Acc], false) :-
    !,
    pg_session_get(Stream, Session),
    (   Session.phase == extended_query
    ->  pg_session_mark_sync_required(Stream)
    ;   true
    ).
process_backend_message(Stream, ready, Bytes, Acc, Acc, true) :-
    !,
    parse_ready_for_query(Bytes, TxStatus),
    pg_session_set_tx_status(Stream, TxStatus),
    pg_session_set_phase(Stream, ready),
    pg_session_clear_sync_required(Stream).
process_backend_message(_Stream, Type, Bytes, Acc, [Type-Bytes|Acc], false).

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
