:- module(pg_types, [
    oid_type/2,
    type_encoder/3,
    type_decoder/3,
    resolve_decoder/2,
    decode_value/3,
    register_type/3,
    extract_data/3
]).

:- use_module(library(base64)).
:- use_module(library(crypto)).
:- use_module(library(utf8)).
:- use_module(library(date)).
:- use_module(library(http/json)).
:- use_module(library(uuid)).
:- use_module(library(postgresql_prolog/pg_protocol), [
    parse_data_row/2,
    bytes_text/2
]).

:- dynamic user_type/3.

oid_type(16, bool).
oid_type(17, bytea).
oid_type(18, char).
oid_type(19, name).
oid_type(20, int8).
oid_type(21, int2).
oid_type(23, int4).
oid_type(25, text).
oid_type(26, oid).
oid_type(700, float4).
oid_type(701, float8).
oid_type(1042, bpchar).
oid_type(1043, varchar).
oid_type(1082, date).
oid_type(1083, time).
oid_type(1114, timestamp).
oid_type(1184, timestamptz).
oid_type(1186, interval).
oid_type(1266, timetz).
oid_type(1700, numeric).
oid_type(2278, void).
oid_type(2950, uuid).
oid_type(3802, jsonb).
oid_type(114, json).

register_type(OID, Name, Module) :-
    assertz(user_type(OID, Name, Module)).

type_encoder(OID, Value, Encoded) :-
    user_type(OID, _, Module),
    !,
    Module:encode(Value, Encoded).
type_encoder(OID, Value, Encoded) :-
    oid_type(OID, Type),
    !,
    encode_type(Type, Value, Encoded).
type_encoder(_, Value, Encoded) :-
    encode_default(Value, Encoded).

encode_type(bool, true, "t").
encode_type(bool, false, "f").
encode_type(bool, 1, "t").
encode_type(bool, 0, "f").

encode_type(int2, Int, Text) :- format(atom(Text), '~d', [Int]).
encode_type(int4, Int, Text) :- format(atom(Text), '~d', [Int]).
encode_type(int8, Int, Text) :- format(atom(Text), '~d', [Int]).

encode_type(float4, Float, Text) :- format(atom(Text), '~g', [Float]).
encode_type(float8, Float, Text) :- format(atom(Text), '~g', [Float]).

encode_type(text, Text, Text).
encode_type(varchar, Text, Text).
encode_type(bpchar, Text, Text).

encode_type(bytea, Bytes, Encoded) :-
    is_list(Bytes),
    phrase(bytea_encode(Bytes), Codes),
    string_codes(Encoded, Codes).

encode_type(json, Term, Json) :-
    term_to_json(Term, Json).
encode_type(jsonb, Term, Json) :-
    term_to_json(Term, Json).

encode_type(timestamp, date(Year,Month,Day,Hour,Min,Sec), Text) :-
    format(atom(Text), '~|~`0t~d~4+`-~|~`0t~d~2+`-~|~`0t~d~2+ ~|~`0t~d~2+:~|~`0t~d~2+:~|~`0t~d~2+',
           [Year, Month, Day, Hour, Min, Sec]).
encode_type(timestamptz, TS, Text) :-
    encode_type(timestamp, TS, Text).

encode_type(date, date(Year,Month,Day), Text) :-
    format(atom(Text), '~|~`0t~d~4+`-~|~`0t~d~2+`-~|~`0t~d~2+', [Year, Month, Day]).

encode_type(uuid, UUID, Text) :-
    (   atom(UUID) -> Text = UUID
    ;   uuid_to_atom(UUID, Text)
    ).

encode_type(numeric, Term, Text) :-
    (   rational(Term, N, D)
    ->  format(atom(Text), '~d/~d', [N, D])
    ;   number(Term)
    ->  format(atom(Text), '~w', [Term])
    ).

encode_default(Value, Text) :-
    (   atom(Value) -> Text = Value
    ;   string(Value) -> Text = Value
    ;   term_to_atom(Value, Text)
    ).

type_decoder(OID, Data, Decoded) :-
    resolve_decoder(OID, Decoder),
    decode_value(Decoder, Data, Decoded).

resolve_decoder(OID, user(Module)) :-
    user_type(OID, _, Module),
    !.
resolve_decoder(OID, builtin(Type)) :-
    oid_type(OID, Type),
    !.
resolve_decoder(_, default).

decode_value(user(Module), Data, Decoded) :-
    Module:decode(Data, Decoded).
decode_value(builtin(Type), Data, Decoded) :-
    decode_type(Type, Data, Decoded).
decode_value(default, Data, Decoded) :-
    decode_default(Data, Decoded).

decode_type(bool, "t", true).
decode_type(bool, "f", false).
decode_type(bool, "true", true).
decode_type(bool, "false", false).

decode_type(int2, Text, Int) :- number_string(Int, Text).
decode_type(int4, Text, Int) :- number_string(Int, Text).
decode_type(int8, Text, Int) :- number_string(Int, Text).

decode_type(float4, Text, Float) :- number_string(Float, Text).
decode_type(float8, Text, Float) :- number_string(Float, Text).

decode_type(text, Text, Text).
decode_type(varchar, Text, Text).
decode_type(bpchar, Text, Text).

decode_type(bytea, Text, Bytes) :-
    string_codes(Text, Codes),
    phrase(bytea_decode(Bytes), Codes).

decode_type(json, Text, Term) :-
    atom_json_dict(Text, Term, []).
decode_type(jsonb, Text, Term) :-
    atom_json_dict(Text, Term, []).

decode_type(timestamp, Text, date(Y,Mo,D,H,Mi,S)) :-
    parse_timestamp(Text, Y, Mo, D, H, Mi, S).
decode_type(timestamptz, Text, date(Y,Mo,D,H,Mi,S)) :-
    parse_timestamp(Text, Y, Mo, D, H, Mi, S).

decode_type(date, Text, date(Y,Mo,D)) :-
    split_string(Text, "-", "", [YS, MoS, DS]),
    number_string(Y, YS),
    number_string(Mo, MoS),
    number_string(D, DS).

decode_type(uuid, Text, UUID) :-
    (   uuid(Text, UUID) -> true
    ;   Text = UUID
    ).

decode_type(numeric, Text, Number) :-
    (   split_string(Text, "/", "", [NS, DS])
    ->  number_string(N, NS),
        number_string(D, DS),
        Number is N / D
    ;   number_string(Number, Text)
    ).

decode_default(Data, Data).

bytea_encode([]) --> [].
bytea_encode([C|T]) -->
    (   { C = 0 } -> "\\\\000"
    ;   { C = 39 } -> "\\\\'"
    ;   { C = 92 } -> "\\\\\\\\"
    ;   { C < 32 ; C > 126 }
    ->  { format(codes(Codes), '\\\\~|~`0t~3r~+', [C]) },
        Codes
    ;   [C]
    ),
    bytea_encode(T).

bytea_decode([]) --> [].
bytea_decode([C|T]) -->
    (   "\\\\\\\\" -> { C = 92 }
    ;   "\\\\'" -> { C = 39 }
    ;   "\\\\000" -> { C = 0 }
    ;   "\\\\" -> octal(C)
    ;   [C]
    ),
    bytea_decode(T).

octal(C) -->
    [O1,O2,O3],
    { code_type(O1, digit(O1n)),
      code_type(O2, digit(O2n)),
      code_type(O3, digit(O3n)),
      C is O1n*64 + O2n*8 + O3n }.

parse_timestamp(Text, Year, Month, Day, Hour, Min, Sec) :-
    split_string(Text, " ", "", [DatePart, TimePart]),
    split_string(DatePart, "-", "", [YS, MS, DS]),
    split_string(TimePart, ":", "", [HS, MiS, SS]),
    number_string(Year, YS),
    number_string(Month, MS),
    number_string(Day, DS),
    number_string(Hour, HS),
    number_string(Min, MiS),
    (   split_string(SS, ".", "", [SecS|_])
    ->  number_string(Sec, SecS)
    ;   number_string(Sec, SS)
    ).

term_to_json(Term, Json) :-
    is_dict(Term),
    !,
    atom_json_dict(Json, Term, []).
term_to_json(Term, Term) :-
    (   string(Term)
    ;   atom(Term)
    ),
    !.
term_to_json(Term, Json) :-
    blob(Term, json_dict),
    atom_json_dict(Json, Term, []).

extract_data(Cols, Msgs, Rows) :-
    columns_decoders(Cols, Decoders),
    extract_data_rows(Msgs, Decoders, [], RevRows),
    reverse(RevRows, Rows).

columns_decoders([], []).
columns_decoders([Col|Cols], [Decoder|Decoders]) :-
    resolve_decoder(Col.type_oid, Decoder),
    columns_decoders(Cols, Decoders).

decode_row(Decoders, Data, Row) :-
    decode_fields(Decoders, Data, Row).

decode_field(Decoder, data(Bytes), Value) :-
    bytes_text(Bytes, Text),
    decode_value(Decoder, Text, Value).
decode_field(_, null, null).

extract_data_rows([], _, Rows, Rows).
extract_data_rows([data_row-Bytes|Msgs], Decoders, Rows0, Rows) :-
    !,
    parse_data_row(Bytes, Data),
    decode_row(Decoders, Data, Row),
    extract_data_rows(Msgs, Decoders, [Row|Rows0], Rows).
extract_data_rows([_|Msgs], Decoders, Rows0, Rows) :-
    extract_data_rows(Msgs, Decoders, Rows0, Rows).

decode_fields([], [], []).
decode_fields([Decoder|Decoders], [Value|Values], [Decoded|DecodedValues]) :-
    decode_field(Decoder, Value, Decoded),
    decode_fields(Decoders, Values, DecodedValues).

:- multifile sandbox:safe_primitive/1.
sandbox:safe_primitive(pg_types:_).
