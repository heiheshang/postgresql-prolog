:- module(pg_prepared, [
    pg_query_params/4,
    pg_prepare_statement/4,
    pg_execute_statement/4,
    pg_forget_prepared_statements/1
]).

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(error)).
:- use_module(library(postgresql_prolog/pg_protocol)).
:- use_module(library(postgresql_prolog/pg_session)).
:- use_module(library(postgresql_prolog/pg_types)).

/** <module> PostgreSQL prepared-query helpers.

Internal extended-query layer for parameterized queries and prepared
statements. This module builds Parse/Bind/Describe/Execute/Sync message
sequences and cooperates with `pg_session.pl` for error recovery.

It is used by `pg.pl` and is not intended as a standalone public interface.
*/

pg_query_params(Connection, SQL, Params, Result) :-
    get_connection_stream(Connection, Stream),
    unspecified_param_oids(Params, ParamOids),
    maplist(encode_untyped_param, Params, EncodedParams),
    parse_message("", SQL, ParamOids, ParseMsg),
    bind_message("", "", [], EncodedParams, [], BindMsg),
    describe_message(portal, "", DescribeMsg),
    execute_message("", 0, ExecuteMsg),
    sync_message(SyncMsg),
    pg_session_prepare_command(Stream, extended_query),
    write_messages(Stream, [ParseMsg, BindMsg, DescribeMsg, ExecuteMsg, SyncMsg]),
    pg_session_read_until_ready(Stream, Msgs),
    handle_query_response(Msgs, Result).

pg_prepare_statement(Connection, Name, SQL, ParamTypes) :-
    get_connection_stream(Connection, Stream),
    normalize_param_types(ParamTypes, ParamOids),
    parse_message(Name, SQL, ParamOids, ParseMsg),
    sync_message(SyncMsg),
    pg_session_prepare_command(Stream, extended_query),
    write_messages(Stream, [ParseMsg, SyncMsg]),
    pg_session_read_until_ready(Stream, Msgs),
    ensure_prepare_success(Msgs),
    pg_session_store_prepared_statement(Stream, Name, ParamOids).

pg_execute_statement(Connection, Name, Params, Result) :-
    get_connection_stream(Connection, Stream),
    (   pg_session_prepared_statement(Stream, Name, ParamOids)
    ->  true
    ;   throw(error(existence_error(prepared_statement, Name), _))
    ),
    build_param_payload(Params, ParamOids, EncodedParams),
    bind_message("", Name, [], EncodedParams, [], BindMsg),
    describe_message(portal, "", DescribeMsg),
    execute_message("", 0, ExecuteMsg),
    sync_message(SyncMsg),
    pg_session_prepare_command(Stream, extended_query),
    write_messages(Stream, [BindMsg, DescribeMsg, ExecuteMsg, SyncMsg]),
    pg_session_read_until_ready(Stream, Msgs),
    handle_query_response(Msgs, Result).

pg_forget_prepared_statements(Stream) :-
    pg_session_clear_prepared_statements(Stream).

unspecified_param_oids([], []).
unspecified_param_oids([_|T], [0|Rest]) :-
    unspecified_param_oids(T, Rest).

normalize_param_types([], []).
normalize_param_types([OID|T], [OID|Rest]) :-
    integer(OID),
    !,
    normalize_param_types(T, Rest).
normalize_param_types([TypeName|T], [OID|Rest]) :-
    oid_type(OID, TypeName),
    !,
    normalize_param_types(T, Rest).
normalize_param_types([Type|_], _) :-
    throw(error(domain_error(pg_parameter_type, Type), _)).

build_param_payload([], [], []).
build_param_payload([Param|Params], [], [Encoded|Rest]) :-
    !,
    encode_untyped_param(Param, Encoded),
    build_param_payload(Params, [], Rest).
build_param_payload([Param|Params], [OID|Oids], [Encoded|Rest]) :-
    encode_typed_param(OID, Param, Encoded),
    build_param_payload(Params, Oids, Rest).
build_param_payload(Params, Oids, _) :-
    throw(error(domain_error(parameter_arity(Params), Oids), _)).

encode_untyped_param(null, null) :- !.
encode_untyped_param(text(Value), text(Text)) :-
    !,
    to_text(Value, Text).
encode_untyped_param(Value, text(Text)) :-
    to_text(Value, Text).

encode_typed_param(_OID, null, null) :- !.
encode_typed_param(OID, Value, text(Text)) :-
    type_encoder(OID, Value, Encoded),
    to_text(Encoded, Text).

to_text(Value, Text) :-
    (   string(Value)
    ->  Text = Value
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   number(Value)
    ->  term_string(Value, Text)
    ;   Value == true
    ->  Text = "true"
    ;   Value == false
    ->  Text = "false"
    ;   type_error(text, Value)
    ).

ensure_prepare_success(Msgs) :-
    (   member(error-Bytes, Msgs)
    ->  parse_error_fields(Bytes, Fields),
        throw(error(pg_prepare_error(Fields), _))
    ;   member(parse_complete-_, Msgs)
    ->  true
    ;   throw(error(protocol_error(missing_parse_complete), _))
    ).

handle_query_response(Msgs, Result) :-
    (   member(error-Bytes, Msgs)
    ->  parse_error_fields(Bytes, Fields),
        Result = error(Fields)
    ;   member(row_desc-DescBytes, Msgs)
    ->  parse_row_description(DescBytes, Cols),
        extract_data(Cols, Msgs, Rows),
        Result = data(Cols, Rows)
    ;   member(cmd_complete-CmdBytes, Msgs)
    ->  parse_command_complete(CmdBytes, Tag),
        Result = ok(Tag)
    ;   member(empty-_, Msgs)
    ->  Result = ok
    ;   Result = unknown(Msgs)
    ).

get_connection_stream(pg_conn(Stream, _, _, _, _, _), Stream).
get_connection_stream(Stream, Stream) :-
    is_stream(Stream).
