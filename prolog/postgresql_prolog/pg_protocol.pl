:- module(pg_protocol, [
    startup_message/3,
    ssl_request/1,
    password_message/2,
    sasl_initial_response/3,
    sasl_response/2,
    query_message/2,
    copy_data_message/2,
    copy_done_message/1,
    copy_fail_message/2,
    parse_message/4,
    bind_message/6,
    execute_message/3,
    sync_message/1,
    terminate_message/1,
    describe_message/3,
    close_message/3,
    flush_message/1,
    read_message/2,
    write_message/2,
    write_messages/2,

    parse_message_type/2,
    parse_error_fields/2,
    parse_authentication/2,
    parse_parameter_status/2,
    parse_backend_key/3,
    parse_notification/2,
    parse_command_complete/2,
    parse_copy_response/2,
    parse_row_description/2,
    parse_data_row/2,
    parse_notice/2,
    parse_ready_for_query/2,
    bytes_integer32/2,
    bytes_text/2
]).

:- use_module(library(crypto)).
:- use_module(library(base64)).
:- use_module(library(utf8)).

msg_type(terminate,     88).
msg_type(query,         81).
msg_type(parse,         80).
msg_type(bind,          66).
msg_type(execute,       69).
msg_type(copy_data,     100).
msg_type(copy_done,     99).
msg_type(copy_fail,     102).
msg_type(sync,          83).
msg_type(flush,         72).
msg_type(close,         67).
msg_type(describe,      68).
msg_type(password,      112).

msg_type(auth,          82).
msg_type(error,         69).
msg_type(parameter,     83).
msg_type(backend_key,   75).
msg_type(ready,         90).
msg_type(row_desc,      84).
msg_type(data_row,      68).
msg_type(cmd_complete,  67).
msg_type(parse_complete,49).
msg_type(bind_complete, 50).
msg_type(close_complete,51).
msg_type(no_data,       110).
msg_type(suspended,     115).
msg_type(portal_sus,    115).
msg_type(notify,        65).
msg_type(empty,         73).

ssl_request(Bytes) :-
    phrase((int32be(8), int32be(80877103)), Bytes).

startup_message(User, Database, Bytes) :-
    build_startup_message(
        (
            int32be(196608),
            startup_parameters(
                [ user-User,
                  database-Database,
                  client_encoding-'UTF8'
                ]
            )
        ),
        Bytes
    ).

password_message(Password, Bytes) :-
    build_message(password, cstring(Password), Bytes).

sasl_initial_response(Mechanism, ClientNonce, Bytes) :-
    length(ClientNonce, ClientNonceLen),
    build_message(
        password,
        (
            cstring(Mechanism),
            int32be(ClientNonceLen),
            bytes(ClientNonce)
        ),
        Bytes
    ).

sasl_response(Data, Bytes) :-
    build_message(password, bytes(Data), Bytes).

query_message(Query, Bytes) :-
    build_message(query, cstring(Query), Bytes).

copy_data_message(Data, Bytes) :-
    build_message(copy_data, bytes(Data), Bytes).

copy_done_message(Bytes) :-
    build_message(copy_done, [], Bytes).

copy_fail_message(Message, Bytes) :-
    build_message(copy_fail, cstring(Message), Bytes).

parse_message(Name, Query, Oids, Bytes) :-
    length(Oids, NumOids),
    build_message(
        parse,
        (
            cstring(Name),
            cstring(Query),
            int16be(NumOids),
            oids(Oids)
        ),
        Bytes
    ).

bind_message(Portal, Statement, Formats, Values, ResultFormats, Bytes) :-
    length(Formats, NumFormats),
    length(Values, NumValues),
    length(ResultFormats, NumResFormats),
    build_message(
        bind,
        (
            cstring(Portal),
            cstring(Statement),
            int16be(NumFormats),
            formats(Formats),
            int16be(NumValues),
            values(Values),
            int16be(NumResFormats),
            formats(ResultFormats)
        ),
        Bytes
    ).

execute_message(Portal, MaxRows, Bytes) :-
    build_message(
        execute,
        (
            cstring(Portal),
            int32be(MaxRows)
        ),
        Bytes
    ).

sync_message(Bytes) :-
    build_message(sync, [], Bytes).

flush_message(Bytes) :-
    build_message(flush, [], Bytes).

terminate_message(Bytes) :-
    build_message(terminate, [], Bytes).

read_message(Stream, Msg) :-
    get_byte(Stream, TypeByte),
    (   TypeByte == -1
    ->  throw(error(unexpected_eof, _))
    ;   true
    ),
    read_n_bytes(Stream, 4, LenBytes),
    bytes_integer32(LenBytes, Len),
    (   Len < 4
    ->  throw(error(protocol_error(invalid_message_length(Len)), _))
    ;   true
    ),
    DataLen is Len - 4,
    read_n_bytes(Stream, DataLen, Data),
    parse_message_type([TypeByte|Data], Msg).

write_message(Stream, Bytes) :-
    forall(member(B, Bytes), put_byte(Stream, B)),
    flush_output(Stream).

write_messages(Stream, Messages) :-
    forall(member(Bytes, Messages), put_bytes_no_flush(Stream, Bytes)),
    flush_output(Stream).

describe_message(Type, Name, Bytes) :-
    close_describe_type_byte(Type, T),
    build_message(
        describe,
        (
            byte(T),
            cstring(Name)
        ),
        Bytes
    ).

close_message(Type, Name, Bytes) :-
    close_describe_type_byte(Type, T),
    build_message(
        close,
        (
            byte(T),
            cstring(Name)
        ),
        Bytes
    ).

parse_message_type([TypeByte|Rest], Type-Rest) :-
    parse_server_message_type(TypeByte, Type).

parse_server_message_type(82, auth) :- !.
parse_server_message_type(69, error) :- !.
parse_server_message_type(83, parameter) :- !.
parse_server_message_type(75, backend_key) :- !.
parse_server_message_type(90, ready) :- !.
parse_server_message_type(84, row_desc) :- !.
parse_server_message_type(68, data_row) :- !.
parse_server_message_type(67, cmd_complete) :- !.
parse_server_message_type(49, parse_complete) :- !.
parse_server_message_type(50, bind_complete) :- !.
parse_server_message_type(51, close_complete) :- !.
parse_server_message_type(71, copy_in) :- !.
parse_server_message_type(72, copy_out) :- !.
parse_server_message_type(87, copy_both) :- !.
parse_server_message_type(110, no_data) :- !.
parse_server_message_type(115, suspended) :- !.
parse_server_message_type(65, notify) :- !.
parse_server_message_type(73, empty) :- !.
parse_server_message_type(78, notice) :- !.
parse_server_message_type(TypeByte, unknown(TypeByte)).

parse_authentication([0,0,0,0|_], ok) :- !.
parse_authentication([0,0,0,3|_], password) :- !.
parse_authentication([0,0,0,5|Rest], md5_salt(Rest)) :- !.
parse_authentication([0,0,0,10|_], sasl) :- !.
parse_authentication([0,0,0,11|Rest], sasl_continue(Rest)) :- !.
parse_authentication([0,0,0,12|Rest], sasl_final(Rest)) :- !.
parse_authentication([B3,B2,B1,B0|_], unknown(AuthType)) :-
    AuthType is (B3 << 24) + (B2 << 16) + (B1 << 8) + B0.

parse_parameter_status(Bytes, Key-Value) :-
    once(phrase((cstring(Key), cstring(Value)), Bytes)).

parse_backend_key([P3,P2,P1,P0,S3,S2,S1,S0|_], PID, Secret) :-
    PID is (P3 << 24) + (P2 << 16) + (P1 << 8) + P0,
    Secret is (S3 << 24) + (S2 << 16) + (S1 << 8) + S0.

parse_notification(Bytes, notification{
                       pid: PID,
                       channel: Channel,
                       payload: Payload
                   }) :-
    once(
        phrase(
            (
                int32be(PID),
                cstring(Channel),
                cstring(Payload)
            ),
            Bytes
        )
    ).

parse_error_fields(Bytes, Fields) :-
    once(phrase(error_fields(Fields), Bytes)).

parse_notice(Bytes, Fields) :-
    parse_error_fields(Bytes, Fields).

parse_ready_for_query([73], idle) :- !.
parse_ready_for_query([84], in_transaction) :- !.
parse_ready_for_query([69], failed_transaction) :- !.
parse_ready_for_query([StatusByte], unknown(StatusByte)).

parse_command_complete(Bytes, Tag) :-
    once(phrase(cstring(Tag), Bytes)).

parse_copy_response(Bytes, copy_response{
                        format: Format,
                        column_formats: ColumnFormats
                    }) :-
    once(phrase(copy_response(Format, ColumnFormats), Bytes)).

parse_row_description(Bytes, Columns) :-
    once(phrase(row_description(Columns), Bytes)).

parse_data_row(Bytes, Values) :-
    once(phrase(data_row(Values), Bytes)).

parse_copy_column_formats(0, []) -->
    [].
parse_copy_column_formats(N, [Format|Formats]) -->
    { N > 0 },
    copy_format(Format),
    { N1 is N - 1 },
    parse_copy_column_formats(N1, Formats).

text_bytes(Text, Bytes) :-
    atom(Text), !,
    atom_codes(Text, Codes),
    codes_bytes(Codes, Bytes).
text_bytes(Text, Bytes) :-
    string(Text), !,
    string_codes(Text, Codes),
    codes_bytes(Codes, Bytes).
text_bytes(Codes, Bytes) :-
    is_list(Codes),
    codes_bytes(Codes, Bytes).

codes_bytes(Codes, Bytes) :-
    string_bytes(Codes, Bytes, utf8).

bytes_text(Bytes, Text) :-
    string_bytes(Text, Bytes, utf8).

startup_parameters_bytes(Parameters, Bytes) :-
    phrase(startup_parameters(Parameters), Bytes).

bytes_integer32([B3,B2,B1,B0], Int) :-
    !,
    Int is (B3 << 24) + (B2 << 16) + (B1 << 8) + B0.
bytes_integer32(Int, [B3,B2,B1,B0]) :-
    integer(Int),
    !,
    B3 is (Int >> 24) /\ 255,
    B2 is (Int >> 16) /\ 255,
    B1 is (Int >> 8) /\ 255,
    B0 is Int /\ 255.

bytes_integer16([B1,B0], Int) :-
    !,
    Int is (B1 << 8) + B0.
bytes_integer16(Int, [B1,B0]) :-
    integer(Int),
    !,
    B1 is (Int >> 8) /\ 255,
    B0 is Int /\ 255.

oids_bytes(Oids, Bytes) :-
    phrase(oids(Oids), Bytes).

formats_bytes(Formats, Bytes) :-
    phrase(formats(Formats), Bytes).

values_bytes(Values, Bytes) :-
    phrase(values(Values), Bytes).

value_bytes(Value, Bytes) :-
    phrase(bind_value(Value), Bytes).

read_n_bytes(_, 0, []) :- !.
read_n_bytes(_, N, _) :-
    N < 0,
    !,
    throw(error(protocol_error(negative_read_length(N)), _)).
read_n_bytes(Stream, N, Bytes) :-
    read_string(Stream, N, String),
    string_length(String, Len),
    (   Len =:= N
    ->  string_codes(String, Bytes)
    ;   throw(error(unexpected_eof, _))
    ).

put_bytes_no_flush(Stream, Bytes) :-
    forall(member(B, Bytes), put_byte(Stream, B)).

build_message(Type, PayloadGrammar, Bytes) :-
    msg_type(Type, TypeByte),
    phrase(PayloadGrammar, Payload),
    length(Payload, PayloadLen),
    TotalLen is PayloadLen + 4,
    phrase((byte(TypeByte), int32be(TotalLen), bytes(Payload)), Bytes).

build_startup_message(PayloadGrammar, Bytes) :-
    phrase(PayloadGrammar, Payload),
    length(Payload, PayloadLen),
    TotalLen is PayloadLen + 4,
    phrase((int32be(TotalLen), bytes(Payload)), Bytes).

close_describe_type_byte(statement, 83).
close_describe_type_byte(_, 80).

byte(Byte) --> [Byte].

int16be(Int) -->
    [B1, B0],
    { integer16_bytes(Int, [B1, B0]) }.

int32be(Int) -->
    [B3, B2, B1, B0],
    { integer32_bytes(Int, [B3, B2, B1, B0]) }.

bytes([]) --> [].
bytes([Byte|Rest]) -->
    [Byte],
    bytes(Rest).

cstring(Text) -->
    { (   nonvar(Text)
      ->  Mode = generate(Text)
      ;   Mode = parse(Text)
      )
    },
    cstring_mode(Mode).

cstring_mode(generate(Text)) -->
    cstring_text(Text).
cstring_mode(parse(Text)) -->
    cstring_parsed_text(Text).

cstring_text(Text) -->
    { text_bytes(Text, TextBytes) },
    bytes(TextBytes),
    [0].

cstring_parsed_text(Text) -->
    cstring_bytes(TextBytes),
    [0],
    { bytes_text(TextBytes, Text) }.

cstring_bytes([]) -->
    peek_byte(0).
cstring_bytes(Bytes) -->
    peek_byte(Byte),
    { Byte =\= 0,
      Bytes = [Byte|Rest]
    },
    [Byte],
    cstring_bytes(Rest).

peek_byte(Byte, [Byte|Rest], [Byte|Rest]).

startup_parameters([]) -->
    [0].
startup_parameters([Key-Value|Parameters]) -->
    cstring(Key),
    cstring(Value),
    startup_parameters(Parameters).

oids([]) --> [].
oids([Oid|Oids]) -->
    int32be(Oid),
    oids(Oids).

formats([]) --> [].
formats([Format|Formats]) -->
    int16be(Format),
    formats(Formats).

values([]) --> [].
values([Value|Values]) -->
    bind_value(Value),
    values(Values).

bind_value(null) -->
    [255, 255, 255, 255].
bind_value(text(Text)) -->
    { text_bytes(Text, Data),
      length(Data, Len)
    },
    int32be(Len),
    bytes(Data).
bind_value(binary(Data)) -->
    { is_list(Data),
      length(Data, Len)
    },
    int32be(Len),
    bytes(Data).

error_fields(Fields) -->
    error_fields([], Fields).

error_fields(Acc, Fields) -->
    peek_byte(Type),
    error_fields_dispatch(Type, Acc, Fields).

error_fields_dispatch(0, Acc, Fields) -->
    [0],
    { Fields = Acc }.
error_fields_dispatch(Type, Acc, Fields) -->
    [Type],
    cstring(Value),
    { Acc1 = [Type-Value|Acc] },
    error_fields(Acc1, Fields).

row_description(Columns) -->
    int16be(NumFields),
    row_description_columns(NumFields, Columns).

row_description_columns(0, []) -->
    [].
row_description_columns(N, [Column|Columns]) -->
    row_description_column(Column),
    { N1 is N - 1 },
    row_description_columns(N1, Columns).

row_description_column(col{
        name: Name,
        table_oid: TableOID,
        column: TableColNo,
        type_oid: TypeOID,
        type_size: TypeSize,
        type_mod: TypeMod,
        format: Format
    }) -->
    cstring(Name),
    int32be(TableOID),
    int16be(TableColNo),
    int32be(TypeOID),
    int16be(TypeSize),
    int32be(TypeMod),
    int16be(Format).

data_row(Values) -->
    int16be(NumFields),
    data_row_values(NumFields, Values).

data_row_values(0, []) -->
    [].
data_row_values(N, [Value|Values]) -->
    data_row_value(Value),
    { N1 is N - 1 },
    data_row_values(N1, Values).

data_row_value(Value) -->
    [B3, B2, B1, B0],
    data_row_value_dispatch(B3, B2, B1, B0, Value).

data_row_value_dispatch(255, 255, 255, 255, null) -->
    [].
data_row_value_dispatch(B3, B2, B1, B0, data(ValueBytes)) -->
    { Length is (B3 << 24) + (B2 << 16) + (B1 << 8) + B0,
      Length =\= 4294967295,
      length(ValueBytes, Length)
    },
    bytes(ValueBytes).

copy_response(Format, ColumnFormats) -->
    copy_format_byte(Format),
    int16be(NumColumns),
    parse_copy_column_formats(NumColumns, ColumnFormats).

copy_format_byte(Format) -->
    byte(FormatCode),
    { parse_copy_format(FormatCode, Format) }.

copy_format(Format) -->
    int16be(FormatCode),
    { parse_copy_format(FormatCode, Format) }.

integer16_bytes(Int, Bytes) :-
    (   integer(Int)
    ->  bytes_integer16(Int, Bytes)
    ;   bytes_integer16(Bytes, Int)
    ).

integer32_bytes(Int, Bytes) :-
    (   integer(Int)
    ->  bytes_integer32(Int, Bytes)
    ;   bytes_integer32(Bytes, Int)
    ).

parse_copy_format(0, text) :- !.
parse_copy_format(1, binary) :- !.
parse_copy_format(Code, unknown(Code)).

:- multifile sandbox:safe_primitive/1.
sandbox:safe_primitive(pg_protocol:_).
