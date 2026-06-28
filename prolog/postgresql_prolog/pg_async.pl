:- module(pg_async, [
    pg_set_notice_processor/2,
    pg_set_notification_processor/2,
    pg_next_notification/2,
    pg_wait_for_notification/3,
    pg_process_async_message/2,
    process_async_message/4
]).

:- use_module(library(debug)).
:- use_module(library(socket)).

:- use_module(library(postgresql_prolog/pg_protocol)).
:- use_module(library(postgresql_prolog/pg_session)).

/** <module> PostgreSQL async message handling.

Internal async layer for notices and notifications.
This module routes backend `NoticeResponse` and `NotificationResponse`
messages into session handlers and queued notifications.

It supports the public LISTEN/NOTIFY surface exported from `pg.pl`, but is
not itself the main user-facing API.
*/

pg_set_notice_processor(Connection, Pred) :-
    must_be(callable, Pred),
    pg_session_set_notice_handler(Connection, Pred).

pg_set_notification_processor(Connection, Pred) :-
    (   Pred == none
    ->  true
    ;   must_be(callable, Pred)
    ),
    pg_session_set_notification_handler(Connection, Pred).

pg_next_notification(Connection, Notification) :-
    pg_session_pop_notification(Connection, Notification).

pg_wait_for_notification(Connection, Timeout, Notification) :-
    (   pg_next_notification(Connection, Notification)
    ->  true
    ;   wait_for_notification(Connection, Timeout, Notification)
    ).

% Store-based wrapper for callers that route a single async message against
% the connection's persisted session (e.g. the COPY side-message handler).
pg_process_async_message(Connection, Msg) :-
    pg_session_get(Connection, Session0),
    process_async_message(Connection, Msg, Session0, Session1),
    pg_session_set(Connection, Session1).

% Explicit State0->State1 async routing, used while the session record is
% being threaded through the read loop without touching the store.
process_async_message(_Connection, notice-Bytes, Session, Session) :-
    !,
    parse_notice(Bytes, Fields),
    (   Session.notice_handler \== none
    ->  Pred = Session.notice_handler,
        call(Pred, Fields)
    ;   debug(pg(notice), 'NOTICE: ~w', [Fields])
    ).
process_async_message(Connection, notify-Bytes, Session0, Session1) :-
    !,
    parse_notification(Bytes, Notification),
    session_push_notification(Session0, Notification, Session1),
    (   Session1.notification_handler \== none
    ->  Pred = Session1.notification_handler,
        call(Pred, Notification)
    ;   true
    ),
    debug(pg(notify), 'Connection ~p received notification ~p',
          [Connection, Notification]).
process_async_message(_Connection, _Msg, Session, Session).

wait_for_notification(Connection, Timeout, Notification) :-
    must_be(number, Timeout),
    Timeout >= 0,
    wait_for_input([Connection], Ready, Timeout),
    (   Ready == []
    ->  throw(error(timeout(pg_wait_for_notification, Timeout), _))
    ;   read_async_until_notification(Connection, Notification)
    ).

read_async_until_notification(Connection, Notification) :-
    read_message(Connection, Msg),
    (   Msg = notify-_
    ->  pg_process_async_message(Connection, Msg),
        pg_next_notification(Connection, Notification)
    ;   Msg = notice-_
    ->  pg_process_async_message(Connection, Msg),
        read_async_until_notification(Connection, Notification)
    ;   throw(error(protocol_error(unexpected_message_while_waiting(Msg)), _))
    ).
