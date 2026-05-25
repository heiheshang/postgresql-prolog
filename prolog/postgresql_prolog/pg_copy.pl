:- module(pg_copy, [
    pg_copy_from/3
]).

:- use_module(library(socket)).
:- use_module(library(utf8)).
:- use_module(library(postgresql_prolog/pg_async)).
:- use_module(library(postgresql_prolog/pg_protocol)).
:- use_module(library(postgresql_prolog/pg_session)).

pg_copy_from(Connection, SQL, Data) :-
    get_connection_stream(Connection, Stream),
    start_copy_in(Stream, SQL, CopyResponse),
    ensure_text_copy(CopyResponse),
    catch(
        send_copy_data_and_finish(Stream, Data),
        Error,
        (
            abort_copy(Stream, Error),
            throw(Error)
        )
    ).

start_copy_in(Stream, SQL, CopyResponse) :-
    pg_session_prepare_command(Stream, copy_in),
    query_message(SQL, Msg),
    write_message(Stream, Msg),
    await_copy_start(Stream, CopyResponse).

await_copy_start(Stream, CopyResponse) :-
    read_message(Stream, Msg),
    (   handle_session_side_message(Stream, Msg)
    ->  await_copy_start(Stream, CopyResponse)
    ;   Msg = copy_in-Bytes
    ->  parse_copy_response(Bytes, CopyResponse)
    ;   Msg = error-Bytes
    ->  pg_session_read_until_ready(Stream, Tail),
        parse_error_fields(Bytes, Fields),
        throw(error(pg_copy_error([error-Bytes|Tail], Fields), _))
    ;   throw(error(protocol_error(unexpected_copy_start_message(Msg)), _))
    ).

ensure_text_copy(copy_response{format: text, column_formats: ColumnFormats}) :-
    forall(member(Format, ColumnFormats), Format == text),
    !.
ensure_text_copy(CopyResponse) :-
    throw(error(not_implemented(copy_format(CopyResponse)), _)).

send_copy_data_and_finish(Stream, Data) :-
    normalize_copy_chunks(Data, Chunks),
    send_copy_chunks(Stream, Chunks),
    finish_copy(Stream).

send_copy_chunks(_, []).
send_copy_chunks(Stream, [Chunk|Chunks]) :-
    copy_chunk_bytes(Chunk, Bytes),
    copy_data_message(Bytes, Msg),
    write_message(Stream, Msg),
    send_copy_chunks(Stream, Chunks).

abort_copy(Stream, Error) :-
    message_to_string(Error, Message),
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

finish_copy(Stream) :-
    wait_for_input([Stream], Ready, 0),
    (   Ready == []
    ->  copy_done_message(DoneMsg),
        write_message(Stream, DoneMsg),
        pg_session_read_until_ready(Stream, Msgs),
        ensure_copy_finish_success(Msgs)
    ;   pg_session_read_until_ready(Stream, Msgs),
        ensure_copy_finish_success(Msgs)
    ).

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
    ->  string_codes(Text, Codes),
        phrase(utf8_codes(Codes), Bytes)
    ;   atom(Text)
    ->  atom_codes(Text, Codes),
        phrase(utf8_codes(Codes), Bytes)
    ).

get_connection_stream(pg_conn(Stream, _, _, _), Stream).
get_connection_stream(Stream, Stream) :-
    is_stream(Stream).
