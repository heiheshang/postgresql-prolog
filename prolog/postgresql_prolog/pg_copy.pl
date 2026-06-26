:- module(pg_copy, [
    pg_copy_from/3,
    pg_copy_to/3
]).

:- use_module(library(socket)).
:- use_module(library(postgresql_prolog/pg_async)).
:- use_module(library(postgresql_prolog/pg_protocol)).
:- use_module(library(postgresql_prolog/pg_session)).
:- use_module(library(postgresql_prolog/pg_types)).

pg_copy_from(Connection, SQL, Data) :-
    get_connection_stream(Connection, Stream),
    start_copy(Stream, copy_in, SQL, CopyResponse),
    setup_call_catcher_cleanup(
        true,
        run_copy_in(Stream, CopyResponse, Data),
        Catcher,
        cleanup_copy_in(Stream, Catcher)
    ).

pg_copy_to(Connection, SQL, Handler) :-
    get_connection_stream(Connection, Stream),
    start_copy(Stream, copy_out, SQL, CopyResponse),
    setup_call_catcher_cleanup(
        true,
        run_copy_out(Stream, CopyResponse, Handler),
        Catcher,
        cleanup_copy_out(Stream, Catcher)
    ).

run_copy_in(Stream, CopyResponse, Data) :-
    copy_in_chunks(CopyResponse, Data, Chunks),
    send_copy_chunks(Stream, Chunks),
    finish_copy_in(Stream).

run_copy_out(Stream, CopyResponse, Handler) :-
    copy_out_mode(CopyResponse, Mode),
    receive_copy_out_chunks(Stream, Mode, Handler).

start_copy(Stream, Phase, SQL, CopyResponse) :-
    pg_session_prepare_command(Stream, Phase),
    query_message(SQL, Msg),
    write_message(Stream, Msg),
    await_copy_start(Stream, Phase, CopyResponse).

await_copy_start(Stream, Phase, CopyResponse) :-
    read_message(Stream, Msg),
    await_copy_start_message(Stream, Phase, Msg, CopyResponse).

await_copy_start_message(Stream, Phase, Msg, CopyResponse) :-
    handle_session_side_message(Stream, Msg),
    !,
    await_copy_start(Stream, Phase, CopyResponse).
await_copy_start_message(_Stream, Phase, MsgType-Bytes, CopyResponse) :-
    expected_copy_start_message(Phase, MsgType),
    !,
    parse_copy_response(Bytes, CopyResponse).
await_copy_start_message(Stream, _Phase, error-Bytes, _CopyResponse) :-
    !,
    pg_session_read_until_ready(Stream, Tail),
    parse_error_fields(Bytes, Fields),
    throw(error(pg_copy_error([error-Bytes|Tail], Fields), _)).
await_copy_start_message(Stream, _Phase, Msg, _CopyResponse) :-
    recover_copy_stream(Stream, Msg),
    throw(error(protocol_error(unexpected_copy_start_message(Msg)), _)).

expected_copy_start_message(copy_in, copy_in).
expected_copy_start_message(copy_out, copy_out).

copy_in_chunks(CopyResponse, Data, Chunks) :-
    (   copy_text_response(CopyResponse)
    ->  normalize_copy_chunks(Data, Chunks)
    ;   copy_binary_response(CopyResponse)
    ->  normalize_binary_copy_rows(Data, TypeOids, Rows),
        binary_copy_chunks(TypeOids, Rows, Chunks)
    ;   throw(error(not_implemented(copy_format(CopyResponse)), _))
    ).

copy_out_mode(CopyResponse, text) :-
    copy_text_response(CopyResponse),
    !.
copy_out_mode(CopyResponse, binary) :-
    copy_binary_response(CopyResponse),
    !.
copy_out_mode(CopyResponse, _) :-
    throw(error(not_implemented(copy_format(CopyResponse)), _)).

copy_text_response(copy_response{format: text, column_formats: ColumnFormats}) :-
    forall(member(Format, ColumnFormats), Format == text).

copy_binary_response(copy_response{format: binary, column_formats: ColumnFormats}) :-
    forall(member(Format, ColumnFormats), Format == binary).

binary_copy_chunks(TypeOids, Rows, [Header|Chunks]) :-
    copy_binary_header(Header),
    binary_copy_row_chunks(TypeOids, Rows, RowChunks),
    copy_binary_trailer(Trailer),
    append(RowChunks, [Trailer], Chunks).

binary_copy_row_chunks(_, [], []).
binary_copy_row_chunks(TypeOids, [Row|Rows], [Chunk|Chunks]) :-
    binary_copy_row_chunk(TypeOids, Row, Chunk),
    binary_copy_row_chunks(TypeOids, Rows, Chunks).

binary_copy_row_chunk(TypeOids, Row, Chunk) :-
    copy_row_values(Row, Values),
    same_length(TypeOids, Values),
    !,
    binary_copy_fields(TypeOids, Values, Fields),
    copy_binary_row(Fields, Chunk).
binary_copy_row_chunk(TypeOids, Row, _) :-
    length(TypeOids, Arity),
    throw(error(domain_error(copy_row_arity(Arity), Row), _)).

binary_copy_fields([], [], []).
binary_copy_fields([TypeOid|TypeOids], [Value|Values], [Field|Fields]) :-
    binary_copy_field(TypeOid, Value, Field),
    binary_copy_fields(TypeOids, Values, Fields).

binary_copy_field(_, null, null) :- !.
binary_copy_field(_, binary(Bytes), binary(Bytes)) :-
    is_byte_list(Bytes),
    !.
binary_copy_field(TypeOid, Value, binary(Bytes)) :-
    type_binary_encoder(TypeOid, Value, Bytes).

receive_copy_out_chunks(Stream, Mode, Handler) :-
    read_message(Stream, Msg),
    receive_copy_out_message(Stream, Mode, Handler, Msg).

receive_copy_out_message(Stream, Mode, Handler, Msg) :-
    handle_session_side_message(Stream, Msg),
    !,
    receive_copy_out_chunks(Stream, Mode, Handler).
receive_copy_out_message(Stream, Mode, Handler, copy_data-Bytes) :-
    !,
    copy_out_chunk(Mode, Bytes, Chunk),
    deliver_copy_chunk(Handler, Chunk),
    receive_copy_out_chunks(Stream, Mode, Handler).
receive_copy_out_message(Stream, _Mode, _Handler, copy_done-_) :-
    !,
    pg_session_read_until_ready(Stream, Msgs),
    ensure_copy_finish_success(Msgs).
receive_copy_out_message(Stream, _Mode, _Handler, error-Bytes) :-
    !,
    pg_session_read_until_ready(Stream, Tail),
    parse_error_fields(Bytes, Fields),
    throw(error(pg_copy_error([error-Bytes|Tail], Fields), _)).
receive_copy_out_message(Stream, _Mode, _Handler, Msg) :-
    recover_copy_stream(Stream, Msg),
    throw(error(protocol_error(unexpected_copy_out_message(Msg)), _)).

copy_out_chunk(text, Bytes, text(Text)) :-
    bytes_text(Bytes, Text).
copy_out_chunk(binary, Bytes, binary(Bytes)).

deliver_copy_chunk(none, _Chunk) :-
    !.
deliver_copy_chunk(Handler, Chunk) :-
    once(call(Handler, Chunk)).

cleanup_copy_in(_Stream, exit) :-
    !.
cleanup_copy_in(Stream, Catcher) :-
    pg_session_get(Stream, Session),
    (   Session.phase == copy_in
    ->  abort_copy(Stream, Catcher)
    ;   true
    ).

cleanup_copy_out(_Stream, exit) :-
    !.
cleanup_copy_out(Stream, _Catcher) :-
    pg_session_get(Stream, Session),
    (   Session.phase == copy_out
    ->  catch(pg_session_read_until_ready(Stream, _), _, true)
    ;   true
    ).

abort_copy(Stream, exception(Error)) :-
    !,
    message_to_string(Error, Message),
    abort_copy_with_message(Stream, Message).
abort_copy(Stream, _Catcher) :-
    Message = "COPY aborted",
    abort_copy_with_message(Stream, Message).

abort_copy_with_message(Stream, Message) :-
    copy_fail_message(Message, FailMsg),
    catch(write_message(Stream, FailMsg), _, true),
    catch(pg_session_read_until_ready(Stream, _), _, true).

ensure_copy_finish_success(Msgs) :-
    (   member(error-Bytes, Msgs)
    ->  parse_error_fields(Bytes, Fields),
        throw(error(pg_copy_error(Msgs, Fields), _))
    ;   member(cmd_complete-_, Msgs)
    ->  true
    ;   throw(error(protocol_error(missing_copy_complete(Msgs)), _))
    ).

finish_copy_in(Stream) :-
    wait_for_input([Stream], Ready, 0),
    (   Ready == []
    ->  copy_done_message(DoneMsg),
        write_message(Stream, DoneMsg),
        pg_session_read_until_ready(Stream, Msgs),
        ensure_copy_finish_success(Msgs)
    ;   maybe_finish_copy_after_server_error(Stream)
    ).

maybe_finish_copy_after_server_error(Stream) :-
    wait_for_input([Stream], Ready, 0),
    (   Ready == []
    ->  true
    ;   pg_session_read_until_ready(Stream, Msgs),
        ensure_copy_finish_success(Msgs)
    ).

recover_copy_stream(Stream, ready-Bytes) :-
    !,
    parse_ready_for_query(Bytes, TxStatus),
    pg_session_set_tx_status(Stream, TxStatus),
    pg_session_set_phase(Stream, ready),
    pg_session_clear_sync_required(Stream).
recover_copy_stream(Stream, _Msg) :-
    pg_session_read_until_ready(Stream, _).

handle_session_side_message(Stream, parameter-Bytes) :-
    !,
    parse_parameter_status(Bytes, KeyValue),
    pg_session_add_parameter(Stream, KeyValue).
handle_session_side_message(Stream, backend_key-Bytes) :-
    !,
    parse_backend_key(Bytes, PID, Secret),
    pg_session_set_backend_key(Stream, PID, Secret).
handle_session_side_message(Stream, notice-Bytes) :-
    !,
    pg_async:pg_process_async_message(Stream, notice-Bytes).
handle_session_side_message(Stream, notify-Bytes) :-
    !,
    pg_async:pg_process_async_message(Stream, notify-Bytes).

normalize_copy_chunks(Data, Chunks) :-
    must_be(nonvar, Data),
    (   Data = chunks(RawChunks)
    ->  must_be(list, RawChunks),
        Chunks = RawChunks
    ;   is_byte_list(Data)
    ->  Chunks = [Data]
    ;   text_chunk(Data)
    ->  Chunks = [Data]
    ;   is_list(Data)
    ->  Chunks = Data
    ;   type_error(copy_data, Data)
    ).

normalize_binary_copy_rows(binary(TypeSpecs, RawRows), TypeOids, Rows) :-
    !,
    must_be(list, TypeSpecs),
    must_be(list, RawRows),
    normalize_copy_type_specs(TypeSpecs, TypeOids),
    Rows = RawRows.
normalize_binary_copy_rows(Data, _, _) :-
    type_error(binary_copy_data, Data).

normalize_copy_type_specs([], []).
normalize_copy_type_specs([TypeSpec|TypeSpecs], [TypeOid|TypeOids]) :-
    normalize_copy_type_spec(TypeSpec, TypeOid),
    normalize_copy_type_specs(TypeSpecs, TypeOids).

normalize_copy_type_spec(TypeOid, TypeOid) :-
    integer(TypeOid),
    !.
normalize_copy_type_spec(TypeName, TypeOid) :-
    string(TypeName),
    !,
    atom_string(TypeAtom, TypeName),
    normalize_copy_type_spec(TypeAtom, TypeOid).
normalize_copy_type_spec(TypeName, TypeOid) :-
    oid_type(TypeOid, TypeName),
    !.
normalize_copy_type_spec(TypeSpec, _) :-
    throw(error(domain_error(copy_type, TypeSpec), _)).

copy_row_values(Values, Values) :-
    is_list(Values),
    !.
copy_row_values(row(Values), Values) :-
    !,
    must_be(list, Values).
copy_row_values(Row, Values) :-
    compound(Row),
    compound_name_arguments(Row, _, Values).

send_copy_chunks(_, []).
send_copy_chunks(Stream, [Chunk|Chunks]) :-
    copy_chunk_bytes(Chunk, Bytes),
    copy_data_message(Bytes, Msg),
    write_message(Stream, Msg),
    maybe_finish_copy_after_server_error(Stream),
    send_copy_chunks(Stream, Chunks).

copy_chunk_bytes(Chunk, Bytes) :-
    is_byte_list(Chunk),
    !,
    Bytes = Chunk.
copy_chunk_bytes(Chunk, Bytes) :-
    text_chunk(Chunk),
    !,
    text_bytes(Chunk, Bytes).
copy_chunk_bytes(Chunk, _) :-
    type_error(copy_chunk, Chunk).

text_chunk(Chunk) :-
    string(Chunk),
    !.
text_chunk(Chunk) :-
    atom(Chunk),
    !.

is_byte_list(Value) :-
    is_list(Value),
    maplist(byte, Value).

byte(Value) :-
    integer(Value),
    between(0, 255, Value).

text_bytes(Text, Bytes) :-
    (   string(Text)
    ->  String = Text
    ;   atom(Text)
    ->  atom_string(Text, String)
    ),
    string_bytes(String, Bytes, utf8).

get_connection_stream(pg_conn(Stream, _, _, _, _, _), Stream).
get_connection_stream(Stream, Stream) :-
    is_stream(Stream).
