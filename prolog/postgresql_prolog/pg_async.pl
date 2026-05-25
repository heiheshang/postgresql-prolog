:- module(pg_async, [
    pg_set_notice_processor/2,
    pg_set_notification_processor/2,
    pg_next_notification/2,
    pg_wait_for_notification/3,
    pg_process_async_message/2
]).

:- use_module(library(debug)).
:- use_module(library(socket)).

:- use_module(library(postgresql_prolog/pg_protocol)).
:- use_module(library(postgresql_prolog/pg_session)).

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

pg_process_async_message(Connection, notice-Bytes) :-
    !,
    parse_notice(Bytes, Fields),
    pg_session_get(Connection, Session),
    (   Session.notice_handler \== none
    ->  Pred = Session.notice_handler,
        call(Pred, Fields)
    ;   debug(pg(notice), 'NOTICE: ~w', [Fields])
    ).
pg_process_async_message(Connection, notify-Bytes) :-
    !,
    parse_notification(Bytes, Notification),
    pg_session_push_notification(Connection, Notification),
    pg_session_get(Connection, Session),
    (   Session.notification_handler \== none
    ->  Pred = Session.notification_handler,
        call(Pred, Notification)
    ;   true
    ),
    debug(pg(notify), 'Connection ~p received notification ~p',
          [Connection, Notification]).
pg_process_async_message(_Connection, _Msg).

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
