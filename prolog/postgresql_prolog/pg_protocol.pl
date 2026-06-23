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

ssl_request([0,0,0,8, 4,210,22,47]).

startup_message(User, Database, Bytes) :-
    bytes_integer32(196608, Version),
    startup_parameters_bytes(
        [ user-User,
          database-Database,
          client_encoding-'UTF8'
        ],
        ParamsBytes
    ),
    append(Version, ParamsBytes, Payload),
    length(Payload, Len),
    Length is Len + 4,
    bytes_integer32(Length, LenBytes),
    append(LenBytes, Payload, Bytes).

password_message(Password, Bytes) :-
    text_bytes(Password, PassBytes),
    length(PassBytes, PassLen),
    TotalLen is PassLen + 5,
    bytes_integer32(TotalLen, LenBytes),
    append([112], LenBytes, Header),
    append(Header, PassBytes, Temp),
    append(Temp, [0], Bytes).

sasl_initial_response(Mechanism, ClientNonce, Bytes) :-
    text_bytes(Mechanism, MechBytes),
    length(MechBytes, MechLen),
    ClientFirstBare = ClientNonce,
    length(ClientFirstBare, CFBLen),
    TotalLen is 4 + MechLen + 1 + 4 + CFBLen,
    bytes_integer32(TotalLen, LenBytes),
    append([112], LenBytes, Header),
    append(Header, MechBytes, Part1),
    append(Part1, [0], Part2),
    bytes_integer32(CFBLen, CFBLenBytes),
    append(Part2, CFBLenBytes, Part3),
    append(Part3, ClientFirstBare, Bytes).

sasl_response(Data, Bytes) :-
    length(Data, DataLen),
    TotalLen is DataLen + 4,
    bytes_integer32(TotalLen, LenBytes),
    append([112], LenBytes, Header),
    append(Header, Data, Bytes).

query_message(Query, Bytes) :-
    text_bytes(Query, QBytes),
    length(QBytes, QLen),
    TotalLen is QLen + 5,
    bytes_integer32(TotalLen, LenBytes),
    append([81], LenBytes, Header),
    append(Header, QBytes, Temp),
    append(Temp, [0], Bytes).

copy_data_message(Data, Bytes) :-
    length(Data, DataLen),
    TotalLen is DataLen + 4,
    bytes_integer32(TotalLen, LenBytes),
    append([100], LenBytes, Header),
    append(Header, Data, Bytes).

copy_done_message([99, 0, 0, 0, 4]).

copy_fail_message(Message, Bytes) :-
    text_bytes(Message, Data),
    length(Data, DataLen),
    TotalLen is DataLen + 5,
    bytes_integer32(TotalLen, LenBytes),
    append([102], LenBytes, Header),
    append(Header, Data, Part1),
    append(Part1, [0], Bytes).

parse_message(Name, Query, Oids, Bytes) :-
    text_bytes(Name, NBytes),
    text_bytes(Query, QBytes),
    length(NBytes, NLen),
    length(QBytes, QLen),
    length(Oids, NumOids),
    bytes_integer16(NumOids, NumOidsBytes),
    oids_bytes(Oids, OidsBytes),
    TotalLen is 4 + NLen + 1 + QLen + 1 + 2 + (NumOids * 4),
    bytes_integer32(TotalLen, LenBytes),
    append([80], LenBytes, Header),
    append(Header, NBytes, Part1),
    append(Part1, [0], Part2),
    append(Part2, QBytes, Part3),
    append(Part3, [0], Part4),
    append(Part4, NumOidsBytes, Part5),
    append(Part5, OidsBytes, Bytes).

bind_message(Portal, Statement, Formats, Values, ResultFormats, Bytes) :-
    text_bytes(Portal, PBytes),
    text_bytes(Statement, SBytes),
    length(PBytes, PLen),
    length(SBytes, SLen),
    length(Formats, NumFormats),
    bytes_integer16(NumFormats, NumFormatsBytes),
    formats_bytes(Formats, FormatsBytes),
    length(Values, NumValues),
    bytes_integer16(NumValues, NumValuesBytes),
    values_bytes(Values, ValuesBytes),
    length(ResultFormats, NumResFormats),
    bytes_integer16(NumResFormats, NumResFormatsBytes),
    formats_bytes(ResultFormats, ResFormatsBytes),
    length(FormatsBytes, FormatsLen),
    length(ValuesBytes, ValuesLen),
    length(ResFormatsBytes, ResFormatsLen),
    TotalLen is 4 + PLen + 1 + SLen + 1 + 2 + FormatsLen + 2 + ValuesLen + 2 + ResFormatsLen,
    bytes_integer32(TotalLen, LenBytes),
    append([66], LenBytes, Header),
    append(Header, PBytes, Part1),
    append(Part1, [0], Part2),
    append(Part2, SBytes, Part3),
    append(Part3, [0], Part4),
    append(Part4, NumFormatsBytes, Part5),
    append(Part5, FormatsBytes, Part6),
    append(Part6, NumValuesBytes, Part7),
    append(Part7, ValuesBytes, Part8),
    append(Part8, NumResFormatsBytes, Part9),
    append(Part9, ResFormatsBytes, Bytes).

execute_message(Portal, MaxRows, Bytes) :-
    text_bytes(Portal, PBytes),
    length(PBytes, PLen),
    bytes_integer32(MaxRows, MaxRowsBytes),
    TotalLen is 4 + PLen + 1 + 4,
    bytes_integer32(TotalLen, LenBytes),
    append([69], LenBytes, Header),
    append(Header, PBytes, Temp),
    append(Temp, [0], Temp2),
    append(Temp2, MaxRowsBytes, Bytes).

sync_message([83, 0, 0, 0, 4]).
flush_message([72, 0, 0, 0, 4]).
terminate_message([88, 0, 0, 0, 4]).

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
    (Type = statement -> T = 83; T = 80),
    text_bytes(Name, NBytes),
    length(NBytes, NLen),
    TotalLen is 4 + 1 + NLen + 1,
    bytes_integer32(TotalLen, LenBytes),
    append([68], LenBytes, Header),
    append(Header, [T], Part1),
    append(Part1, NBytes, Part2),
    append(Part2, [0], Bytes).

close_message(Type, Name, Bytes) :-
    (Type = statement -> T = 83; T = 80),
    text_bytes(Name, NBytes),
    length(NBytes, NLen),
    TotalLen is 4 + 1 + NLen + 1,
    bytes_integer32(TotalLen, LenBytes),
    append([67], LenBytes, Header),
    append(Header, [T], Part1),
    append(Part1, NBytes, Part2),
    append(Part2, [0], Bytes).

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

parse_authentication(Bytes, Method) :-
    Bytes = [B3,B2,B1,B0|Rest],
    bytes_integer32([B3,B2,B1,B0], AuthType),
    (   AuthType = 0 -> Method = ok
    ;   AuthType = 3 -> Method = password
    ;   AuthType = 5 -> Method = md5_salt(Rest)
    ;   AuthType = 10 -> Method = sasl
    ;   AuthType = 11 -> Method = sasl_continue(Rest)
    ;   AuthType = 12 -> Method = sasl_final(Rest)
    ;   Method = unknown(AuthType)
    ).

parse_parameter_status(Bytes, Key-Value) :-
    split_null(Bytes, KeyBytes, Rest),
    split_null(Rest, ValueBytes, _),
    bytes_text(KeyBytes, Key),
    bytes_text(ValueBytes, Value).

parse_backend_key([B3,B2,B1,B0|Rest], PID, Secret) :-
    bytes_integer32([B3,B2,B1,B0], PID),
    Rest = [S3,S2,S1,S0|_],
    bytes_integer32([S3,S2,S1,S0], Secret).

parse_notification([P3,P2,P1,P0|Rest], notification{
                       pid: PID,
                       channel: Channel,
                       payload: Payload
                   }) :-
    bytes_integer32([P3,P2,P1,P0], PID),
    split_null(Rest, ChannelBytes, Rest1),
    split_null(Rest1, PayloadBytes, _),
    bytes_text(ChannelBytes, Channel),
    bytes_text(PayloadBytes, Payload).

parse_error_fields(Bytes, Fields) :-
    parse_fields(Bytes, [], Fields).

parse_fields([0], Acc, Acc) :- !.
parse_fields([Type|Bytes], Acc, Fields) :-
    split_null(Bytes, ValueBytes, Rest),
    bytes_text(ValueBytes, Value),
    parse_fields(Rest, [Type-Value|Acc], Fields).

parse_notice(Bytes, Fields) :-
    parse_error_fields(Bytes, Fields).

parse_ready_for_query([StatusByte], Status) :-
    parse_tx_status(StatusByte, Status).

parse_command_complete(Bytes, Tag) :-
    split_null(Bytes, TagBytes, _),
    bytes_text(TagBytes, Tag).

parse_copy_response([FormatByte, C1, C0|Rest], copy_response{
                        format: Format,
                        column_formats: ColumnFormats
                    }) :-
    parse_copy_format(FormatByte, Format),
    bytes_integer16([C1, C0], NumColumns),
    parse_copy_column_formats(NumColumns, Rest, ColumnFormats).

parse_row_description(Bytes, Columns) :-
    Bytes = [B1,B0|Rest],
    bytes_integer16([B1,B0], NumFields),
    parse_fields_desc(NumFields, Rest, Columns).

parse_fields_desc(0, _, []) :- !.
parse_fields_desc(N, Bytes, [Col|Cols]) :-
    split_null(Bytes, NameBytes, Rest1),
    bytes_text(NameBytes, Name),
    Rest1 = [
        T3,T2,T1,T0,
        TB1,TB0,
        A3,A2,A1,A0,
        TS1,TS0,
        TM3,TM2,TM1,TM0,
        Fmt1,Fmt0
    |Rest2],
    bytes_integer32([T3,T2,T1,T0], TableOID),
    bytes_integer16([TB1,TB0], TableColNo),
    bytes_integer32([A3,A2,A1,A0], TypeOID),
    bytes_integer16([TS1,TS0], TypeSize),
    bytes_integer32([TM3,TM2,TM1,TM0], TypeMod),
    bytes_integer16([Fmt1,Fmt0], Format),
    N1 is N - 1,
    Col = col{
        name: Name,
        table_oid: TableOID,
        column: TableColNo,
        type_oid: TypeOID,
        type_size: TypeSize,
        type_mod: TypeMod,
        format: Format
    },
    parse_fields_desc(N1, Rest2, Cols).

parse_data_row(Bytes, Values) :-
    Bytes = [B1,B0|Rest],
    bytes_integer16([B1,B0], NumFields),
    parse_values(NumFields, Rest, Values).

parse_values(0, _, []) :- !.
parse_values(N, [M3,M2,M1,M0|Rest], [Value|Values]) :-
    (   [M3,M2,M1,M0] = [255,255,255,255]
    ->  Value = null,
        Rest1 = Rest
    ;   bytes_integer32([M3,M2,M1,M0], Length),
        Length >= 0
    ->  length(ValueBytes, Length),
        append(ValueBytes, Rest1, Rest),
        Value = data(ValueBytes)
    ),
    N1 is N - 1,
    parse_values(N1, Rest1, Values).

parse_copy_column_formats(0, [], []) :- !.
parse_copy_column_formats(N, [F1,F0|Rest], [Format|Formats]) :-
    N > 0,
    bytes_integer16([F1, F0], FormatCode),
    parse_copy_format(FormatCode, Format),
    N1 is N - 1,
    parse_copy_column_formats(N1, Rest, Formats).

split_null(Bytes, Before, After) :-
    append(Before, [0|After], Bytes), !.

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
    phrase(utf8_codes(Codes), Bytes).

bytes_text(Bytes, Text) :-
    phrase(utf8_codes(Codes), Bytes),
    string_codes(Text, Codes).

startup_parameters_bytes(Parameters, Bytes) :-
    startup_parameters_bytes(Parameters, [0], Bytes).

startup_parameters_bytes([], Tail, Tail).
startup_parameters_bytes([Key-Value|Parameters], Tail, Bytes) :-
    text_bytes(Key, KeyBytes),
    text_bytes(Value, ValueBytes),
    append(KeyBytes, [0|Rest1], Bytes),
    append(ValueBytes, [0|Rest2], Rest1),
    startup_parameters_bytes(Parameters, Tail, Rest2).

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

oids_bytes([], []).
oids_bytes([Oid|Oids], Bytes) :-
    bytes_integer32(Oid, OidBytes),
    oids_bytes(Oids, Rest),
    append(OidBytes, Rest, Bytes).

formats_bytes([], []).
formats_bytes([Fmt|Fmts], [B1,B0|Rest]) :-
    bytes_integer16(Fmt, [B1,B0]),
    formats_bytes(Fmts, Rest).

values_bytes([], []).
values_bytes([Value|Values], Bytes) :-
    value_bytes(Value, ValueBytes),
    values_bytes(Values, Rest),
    append(ValueBytes, Rest, Bytes).

value_bytes(null, [255,255,255,255]).
value_bytes(text(Atom), Bytes) :-
    text_bytes(Atom, Data),
    length(Data, Len),
    bytes_integer32(Len, LenBytes),
    append(LenBytes, Data, Bytes).
value_bytes(binary(Bin), Bytes) :-
    is_list(Bin),
    length(Bin, Len),
    bytes_integer32(Len, LenBytes),
    append(LenBytes, Bin, Bytes).

read_n_bytes(_, 0, []) :- !.
read_n_bytes(_, N, _) :-
    N < 0,
    !,
    throw(error(protocol_error(negative_read_length(N)), _)).
read_n_bytes(Stream, N, [B|Bs]) :-
    get_byte(Stream, B),
    (   B == -1
    ->  throw(error(unexpected_eof, _))
    ;   true
    ),
    N1 is N - 1,
    read_n_bytes(Stream, N1, Bs).

put_bytes_no_flush(Stream, Bytes) :-
    forall(member(B, Bytes), put_byte(Stream, B)).

parse_tx_status(73, idle) :- !.
parse_tx_status(84, in_transaction) :- !.
parse_tx_status(69, failed_transaction) :- !.
parse_tx_status(StatusByte, unknown(StatusByte)).

parse_copy_format(0, text) :- !.
parse_copy_format(1, binary) :- !.
parse_copy_format(Code, unknown(Code)).

:- multifile sandbox:safe_primitive/1.
sandbox:safe_primitive(pg_protocol:_).
