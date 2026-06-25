:- module(pg, [
    pg_connect/2,
    pg_connect/3,
    pg_disconnect/1,
    pg_query/3,
    pg_query/4,
    pg_prepare/4,
    pg_execute/4,
    pg_execute/3,
    pg_transaction/2,
    pg_listen/3,
    pg_notify/3,
    pg_wait_for_notification/3,
    pg_copy_from/3,
    pg_copy_to/3,
    pg_backend_pid/2,
    pg_server_parameter/3,
    pg_last_command_tag/2,
    pg_escape_identifier/2,
    pg_escape_literal/2,
    pg_set_notice_processor/2
]).

:- use_module(library(apply)).
:- use_module(library(socket)).
:- use_module(library(option)).

:- use_module(library(postgresql_prolog/pg_async), [
    pg_set_notification_processor/2
]).
:- use_module(library(postgresql_prolog/pg_auth)).
:- use_module(library(postgresql_prolog/pg_copy), []).
:- use_module(library(postgresql_prolog/pg_prepared)).
:- use_module(library(postgresql_prolog/pg_protocol)).
:- use_module(library(postgresql_prolog/pg_session)).
:- use_module(library(postgresql_prolog/pg_types)).

:- meta_predicate pg_transaction(+, 0).

pg_connect(Host:Port, Connection) :-
    pg_connect(Host:Port, Connection, []).

pg_connect(Host:Port, Connection, Options) :-
    option(user(User), Options, postgres),
    option(password(Pass), Options, ""),
    option(database(DB), Options, User),
    option(ssl(SSL), Options, false),
    (   SSL == true
    ->  throw(error(not_implemented(ssl), _))
    ;   true
    ),
    setup_call_catcher_cleanup(
        open_connection_stream(Host, Port, Stream),
        init_connection(Stream, User, Pass, DB, Connection),
        Catcher,
        cleanup_failed_connect(Catcher, Stream)
    ).

pg_disconnect(Connection) :-
    get_connection_stream(Connection, Stream),
    setup_call_cleanup(
        true,
        send_terminate_message(Stream),
        cleanup_connection_stream(Stream)
    ).

pg_query(Connection, SQL, Result) :-
    pg_query(Connection, SQL, [], Result).

pg_query(Connection, SQL, Params, Result) :-
    (   Params == []
    ->  simple_query(Connection, SQL, Result)
    ;   pg_prepared:pg_query_params(Connection, SQL, Params, Result)
    ).

pg_prepare(Connection, Name, SQL, ParamTypes) :-
    pg_prepared:pg_prepare_statement(Connection, Name, SQL, ParamTypes).

pg_execute(Connection, Name, Params, Result) :-
    pg_prepared:pg_execute_statement(Connection, Name, Params, Result).

pg_execute(Connection, Name, Result) :-
    pg_prepared:pg_execute_statement(Connection, Name, [], Result).

pg_transaction(Connection, Goal) :-
    pg_query(Connection, "BEGIN", BeginResult),
    ensure_command_success(BeginResult, pg_transaction_begin),
    setup_call_catcher_cleanup(
        true,
        once(call(Goal)),
        Catcher,
        finish_transaction(Connection, Catcher)
    ).

pg_listen(Connection, Channel, Handler) :-
    get_connection_stream(Connection, Stream),
    pg_async:pg_set_notification_processor(Stream, Handler),
    pg_escape_identifier(Channel, EscapedChannel),
    format(string(SQL), "LISTEN ~w", [EscapedChannel]),
    pg_query(Connection, SQL, Result),
    ensure_command_success(Result, pg_listen).

pg_notify(Connection, Channel, Payload) :-
    pg_escape_identifier(Channel, EscapedChannel),
    pg_escape_literal(Payload, EscapedPayload),
    format(string(SQL), "NOTIFY ~w, ~w", [EscapedChannel, EscapedPayload]),
    pg_query(Connection, SQL, Result),
    ensure_command_success(Result, pg_notify).

pg_wait_for_notification(Connection, Timeout, Notification) :-
    get_connection_stream(Connection, Stream),
    pg_async:pg_wait_for_notification(Stream, Timeout, Notification).

pg_copy_from(Connection, SQL, Data) :-
    pg_copy:pg_copy_from(Connection, SQL, Data).

pg_copy_to(_, _, _) :-
    throw(error(not_implemented(pg_copy_to), _)).

pg_backend_pid(Connection, PID) :-
    get_connection_stream(Connection, Stream),
    pg_session_backend_pid(Stream, PID).

pg_server_parameter(Connection, Name, Value) :-
    get_connection_stream(Connection, Stream),
    pg_session_server_parameter(Stream, Name, Value).

pg_last_command_tag(Connection, Tag) :-
    get_connection_stream(Connection, Stream),
    pg_session_last_command_tag(Stream, Tag).

pg_escape_identifier(Identifier, Escaped) :-
    text_chars(Identifier, Chars),
    escape_double_quotes(Chars, EscapedChars),
    atom_chars(Escaped, ['"'|EscapedChars]).

pg_escape_literal(Literal, Escaped) :-
    text_chars(Literal, Chars),
    escape_single_quotes(Chars, EscapedChars),
    atom_chars(Escaped, ['\''|EscapedChars]).

pg_set_notice_processor(Connection, Pred) :-
    get_connection_stream(Connection, Stream),
    pg_async:pg_set_notice_processor(Stream, Pred).

init_connection(Stream, User, Pass, DB, pg_conn(Stream, PID, Secret, Params)) :-
    pg_session_open(Stream),
    startup_message(User, DB, Startup),
    write_message(Stream, Startup),
    pg_auth:pg_receive_auth(Stream, User, Pass),
    pg_session_read_until_ready(Stream, Msgs),
    (   member(error-Bytes, Msgs)
    ->  parse_error_fields(Bytes, Fields),
        throw(error(connection_error(Fields), _))
    ;   true
    ),
    pg_session_backend_pid(Stream, PID),
    pg_session_get(Stream, Session),
    Secret = Session.cancel_secret,
    Params = Session.server_params.

open_connection_stream(Host, Port, Stream) :-
    tcp_socket(Socket),
    tcp_connect(Socket, Host:Port, Stream),
    set_stream(Stream, type(binary)),
    set_stream(Stream, encoding(octet)).

cleanup_failed_connect(exit, _) :-
    !.
cleanup_failed_connect(_, Stream) :-
    cleanup_connection_state(Stream),
    close(Stream, [force(true)]).

send_terminate_message(Stream) :-
    terminate_message(Msg),
    write_message(Stream, Msg).

cleanup_connection_stream(Stream) :-
    cleanup_connection_state(Stream),
    close(Stream, [force(true)]).

cleanup_connection_state(Stream) :-
    pg_prepared:pg_forget_prepared_statements(Stream),
    pg_session_close(Stream).

finish_transaction(Connection, exit) :-
    !,
    pg_query(Connection, "COMMIT", CommitResult),
    ensure_command_success(CommitResult, pg_transaction_commit).
finish_transaction(Connection, exception(Error)) :-
    !,
    rollback_transaction(Connection),
    throw(Error).
finish_transaction(Connection, _) :-
    rollback_transaction(Connection).

rollback_transaction(Connection) :-
    pg_query(Connection, "ROLLBACK", RollbackResult),
    ensure_command_success(RollbackResult, pg_transaction_rollback).

simple_query(Connection, SQL, Result) :-
    get_connection_stream(Connection, Stream),
    pg_session_prepare_command(Stream, simple_query),
    query_message(SQL, Msg),
    write_message(Stream, Msg),
    pg_session_read_until_ready(Stream, Msgs),
    handle_simple_query_response(Msgs, Result).

ensure_command_success(ok, _) :- !.
ensure_command_success(ok(_), _) :- !.
ensure_command_success(error(Fields), Context) :-
    throw_context_error(Context, Fields).
ensure_command_success(Result, Context) :-
    throw(error(protocol_error(unexpected_result(Context, Result)), _)).

ensure_data_success(data(_, [[true]]), _) :- !.
ensure_data_success(data(_, []), _) :- !.
ensure_data_success(error(Fields), Context) :-
    throw_context_error(Context, Fields).
ensure_data_success(Result, Context) :-
    throw(error(protocol_error(unexpected_result(Context, Result)), _)).

throw_context_error(Context, Fields) :-
    Error =.. [Context, Fields],
    throw(error(Error, _)).

handle_simple_query_response(Msgs, Result) :-
    (   last_result_segment(Msgs, Segment)
    ->  handle_result_segment(Segment, Result)
    ;   Result = unknown(Msgs)
    ).

handle_result_segment(Segment, error(Fields)) :-
    member(error-Bytes, Segment),
    !,
    parse_error_fields(Bytes, Fields).
handle_result_segment(Segment, data(Cols, Rows)) :-
    last_result_row_desc(Segment, DescBytes),
    !,
    parse_row_description(DescBytes, Cols),
    extract_data(Cols, Segment, Rows).
handle_result_segment(Segment, ok(Tag)) :-
    last_cmd_complete(Segment, CmdBytes),
    !,
    parse_command_complete(CmdBytes, Tag).
handle_result_segment(Segment, ok) :-
    member(empty-_, Segment).

extract_data(Cols, Msgs, Rows) :-
    findall(Row,
        (   member(data_row-Bytes, Msgs),
            parse_data_row(Bytes, Data),
            decode_row(Cols, Data, Row)
        ),
        Rows).

decode_row(Cols, Data, Row) :-
    maplist(decode_field, Cols, Data, Row).

decode_field(Col, data(Bytes), Value) :-
    TypeOID = Col.type_oid,
    pg_protocol:bytes_text(Bytes, Text),
    type_decoder(TypeOID, Text, Value).
decode_field(_, null, null).

extract_result_rows(Cols, Msgs, Rows) :-
    last_result_segment(Msgs, Segment),
    extract_data(Cols, Segment, Rows).

take_until_terminal([], []).
take_until_terminal([Message|_], [Message]) :-
    result_terminal_message(Message),
    !.
take_until_terminal([Message|Messages], [Message|Rest]) :-
    take_until_terminal(Messages, Rest).

last_result_row_desc(Msgs, DescBytes) :-
    member(row_desc-DescBytes, Msgs).

last_cmd_complete(Msgs, CmdBytes) :-
    member(cmd_complete-CmdBytes, Msgs).

last_result_segment(Msgs, Segment) :-
    last_result_segment(Msgs, none, Segment).

last_result_segment([], none, _) :-
    fail.
last_result_segment([], Segment, Segment).
last_result_segment([Message|Messages], _Current, Segment) :-
    result_segment_start(Message),
    !,
    take_until_terminal([Message|Messages], Next),
    drop_result_messages([Message|Messages], Remaining),
    last_result_segment(Remaining, Next, Segment).
last_result_segment([_|Messages], Current, Segment) :-
    last_result_segment(Messages, Current, Segment).

result_segment_start(row_desc-_).
result_segment_start(cmd_complete-_).
result_segment_start(error-_).
result_segment_start(empty-_).

result_terminal_message(cmd_complete-_).
result_terminal_message(error-_).
result_terminal_message(empty-_).

drop_result_messages([], []).
drop_result_messages([Message|Messages], Messages) :-
    result_terminal_message(Message),
    !.
drop_result_messages([_|Messages], Remaining) :-
    drop_result_messages(Messages, Remaining).

get_connection_stream(pg_conn(Stream, _, _, _), Stream).
get_connection_stream(Stream, Stream) :-
    is_stream(Stream).

text_chars(Text, Chars) :-
    (   string(Text)
    ->  string_chars(Text, Chars)
    ;   atom(Text)
    ->  atom_chars(Text, Chars)
    ;   is_list(Text)
    ->  Chars = Text
    ;   type_error(text, Text)
    ).

escape_double_quotes([], ['"']).
escape_double_quotes(['"'|Tail], ['"','"'|EscapedTail]) :-
    !,
    escape_double_quotes(Tail, EscapedTail).
escape_double_quotes([Char|Tail], [Char|EscapedTail]) :-
    escape_double_quotes(Tail, EscapedTail).

escape_single_quotes([], ['\'']).
escape_single_quotes(['\''|Tail], ['\'','\''|EscapedTail]) :-
    !,
    escape_single_quotes(Tail, EscapedTail).
escape_single_quotes([Char|Tail], [Char|EscapedTail]) :-
    escape_single_quotes(Tail, EscapedTail).

:- multifile sandbox:safe_primitive/1.
sandbox:safe_primitive(pg:_).
