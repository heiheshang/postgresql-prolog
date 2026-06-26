:- module(test_postgresql, [run_all_tests/0]).

:- use_module(library(plunit)).

setup_local_pack_path :-
    prolog_load_context(directory, TestDir),
    directory_file_path(TestDir, '..', RootDir),
    directory_file_path(RootDir, prolog, PrologDir),
    asserta(user:file_search_path(library, PrologDir)).

:- initialization(setup_local_pack_path, now).

:- use_module(library(postgresql_prolog/pg)).
:- use_module(library(postgresql_prolog/pg_protocol)).

pg_env(Var, Default, Value) :-
    (   getenv(Var, Raw),
        Raw \== ''
    ->  Value = Raw
    ;   Value = Default
    ).

connection_options(Host, Port, Options) :-
    pg_env('PGHOST', '127.0.0.1', HostString),
    atom_string(Host, HostString),
    pg_env('PGPORT', '5432', PortString),
    atom_number(PortString, Port),
    pg_env('PGUSER', 'postgres', User),
    pg_env('PGDATABASE', 'postgres', Database),
    BaseOptions = [user(User), database(Database)],
    (   getenv('PGPASSWORD', Password),
        Password \== ''
    ->  Options = [password(Password)|BaseOptions]
    ;   Options = BaseOptions
    ).

connect_test_db(Connection) :-
    connection_options(Host, Port, Options),
    pg_connect(Host:Port, Connection, Options).

with_connection(Goal) :-
    setup_call_cleanup(
        connect_test_db(Connection),
        once(call(Goal, Connection)),
        pg_disconnect(Connection)
    ).

with_two_connections(Goal) :-
    setup_call_cleanup(
        connect_test_db(Connection1),
        setup_call_cleanup(
            connect_test_db(Connection2),
            once(call(Goal, Connection1, Connection2)),
            pg_disconnect(Connection2)
        ),
        pg_disconnect(Connection1)
    ).

:- begin_tests(pg_driver).

test(connect_success) :-
    with_connection(
        [Connection]>>assertion(Connection = pg_conn(_, _, _, _, _, _))
    ).

test(connect_failure_cleans_session_state) :-
    connection_options(Host, Port, Options),
    catch(
        pg_connect(Host:Port,
                   _,
                   [database("pg_driver_missing_db_for_cleanup_test")|Options]),
        Error,
        true
    ),
    assertion(nonvar(Error)),
    assertion(\+ pg_session:session_state(_, _)).

test(startup_message_sets_client_encoding_utf8) :-
    startup_message("alice", "example_db", Bytes),
    startup_message_parameters(Bytes, Parameters),
    assertion(member("user"-"alice", Parameters)),
    assertion(member("database"-"example_db", Parameters)),
    assertion(member("client_encoding"-"UTF8", Parameters)).

test(parse_message_encodes_named_statement_and_oids) :-
    parse_message("stmt", "SELECT $1", [23, 25], Bytes),
    assertion(Bytes == [
        80, 0, 0, 0, 29,
        115, 116, 109, 116, 0,
        83, 69, 76, 69, 67, 84, 32, 36, 49, 0,
        0, 2,
        0, 0, 0, 23,
        0, 0, 0, 25
    ]).

test(bind_message_encodes_formats_values_and_result_formats) :-
    bind_message("p", "s", [0, 1], [text("x"), null, binary([1, 2])], [1], Bytes),
    assertion(Bytes == [
        66, 0, 0, 0, 35,
        112, 0,
        115, 0,
        0, 2,
        0, 0, 0, 1,
        0, 3,
        0, 0, 0, 1, 120,
        255, 255, 255, 255,
        0, 0, 0, 2, 1, 2,
        0, 1,
        0, 1
    ]).

test(execute_message_encodes_portal_and_max_rows) :-
    execute_message("portal", 10, Bytes),
    assertion(Bytes == [
        69, 0, 0, 0, 15,
        112, 111, 114, 116, 97, 108, 0,
        0, 0, 0, 10
    ]).

test(sync_flush_and_terminate_messages_use_empty_payload_frames) :-
    sync_message(SyncBytes),
    flush_message(FlushBytes),
    terminate_message(TerminateBytes),
    assertion(SyncBytes == [83, 0, 0, 0, 4]),
    assertion(FlushBytes == [72, 0, 0, 0, 4]),
    assertion(TerminateBytes == [88, 0, 0, 0, 4]).

test(parse_error_fields_preserves_existing_reverse_accumulator_order) :-
    parse_error_fields([77, 111, 111, 112, 115, 0, 67, 50, 51, 53, 48, 53, 0, 0], Fields),
    assertion(Fields == [67-"23505", 77-"oops"]).

test(parse_authentication_decodes_known_and_unknown_methods) :-
    parse_authentication([0, 0, 0, 0], Ok),
    parse_authentication([0, 0, 0, 3], Password),
    parse_authentication([0, 0, 0, 5, 1, 2, 3, 4], MD5),
    parse_authentication([0, 0, 0, 10], SASL),
    parse_authentication([0, 0, 0, 11, 9, 8], SASLContinue),
    parse_authentication([0, 0, 0, 12, 7, 6], SASLFinal),
    parse_authentication([0, 0, 0, 99], Unknown),
    assertion(Ok == ok),
    assertion(Password == password),
    assertion(MD5 == md5_salt([1, 2, 3, 4])),
    assertion(SASL == sasl),
    assertion(SASLContinue == sasl_continue([9, 8])),
    assertion(SASLFinal == sasl_final([7, 6])),
    assertion(Unknown == unknown(99)).

test(parse_backend_key_decodes_pid_and_secret) :-
    parse_backend_key([0, 0, 0, 42, 0, 0, 1, 2], PID, Secret),
    assertion(PID == 42),
    assertion(Secret == 258).

test(parse_ready_for_query_decodes_known_and_unknown_statuses) :-
    parse_ready_for_query([73], Idle),
    parse_ready_for_query([84], InTransaction),
    parse_ready_for_query([69], Failed),
    parse_ready_for_query([88], Unknown),
    assertion(Idle == idle),
    assertion(InTransaction == in_transaction),
    assertion(Failed == failed_transaction),
    assertion(Unknown == unknown(88)).

test(parse_copy_response_decodes_overall_and_column_formats) :-
    parse_copy_response([0, 0, 2, 0, 0, 0, 1], Response),
    assertion(Response == copy_response{
        format: text,
        column_formats: [text, binary]
    }).

test(parse_row_description_decodes_column_metadata) :-
    parse_row_description(
        [0, 1,
         110, 0,
         0, 0, 0, 1,
         0, 2,
         0, 0, 0, 23,
         0, 4,
         0, 0, 0, 5,
         0, 0],
        Columns
    ),
    assertion(Columns == [col{
        name: "n",
        table_oid: 1,
        column: 2,
        type_oid: 23,
        type_size: 4,
        type_mod: 5,
        format: 0
    }]).

test(parse_data_row_decodes_data_and_null_fields) :-
    parse_data_row(
        [0, 3,
         0, 0, 0, 1, 97,
         255, 255, 255, 255,
         0, 0, 0, 0],
        Values
    ),
    assertion(Values == [data([97]), null, data([])]).

test(empty_query) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "", Result),
            assertion(Result == ok)
        )
    ).

test(select_one) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "SELECT 1 AS n", Result),
            Result = data([Col], [[1]]),
            assertion(get_dict(name, Col, "n")),
            assertion(get_dict(type_oid, Col, 23))
        )
    ).

test(select_null) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "SELECT NULL AS x", Result),
            Result = data([Col], [[null]]),
            assertion(get_dict(name, Col, "x"))
        )
    ).

test(parameterized_query) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "SELECT $1::int AS n, $2::text AS t", [1, "alpha"], Result),
            Result = data([ColN, ColT], [[1, "alpha"]]),
            assertion(get_dict(name, ColN, "n")),
            assertion(get_dict(name, ColT, "t"))
        )
    ).

test(prepare_and_execute) :-
    with_connection(
        [Connection]>>(
            pg_prepare(Connection, test_stmt, "SELECT $1::int + 1 AS n", [int4]),
            pg_execute(Connection, test_stmt, [41], Result),
            Result = data([Col], [[42]]),
            assertion(get_dict(name, Col, "n"))
        )
    ).

test(listen_notify_roundtrip) :-
    with_two_connections(
        [Listener, Notifier]>>(
            pg_listen(Listener, "pg_driver_events", none),
            pg_notify(Notifier, "pg_driver_events", "alpha"),
            pg_wait_for_notification(Listener, 2.0, Notification),
            assertion(Notification = notification{
                channel:"pg_driver_events",
                payload:"alpha",
                pid:_
            })
        )
    ).

test(returning_from_insert) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_return_insert(id int)", _),
            pg_query(Connection,
                     "INSERT INTO pg_return_insert(id) VALUES (3) RETURNING id",
                     Result),
            assertion(Result = data([_], [[3]]))
        )
    ).

test(returning_from_update) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_return_update(id int, value text)", _),
            pg_query(Connection, "INSERT INTO pg_return_update VALUES (1, 'a'), (2, 'b')", _),
            pg_query(Connection,
                     "UPDATE pg_return_update SET value = 'z' RETURNING id",
                     Result),
            assertion(Result = data([_], [[1], [2]]))
        )
    ).

test(returning_from_delete) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_return_delete(id int, value text)", _),
            pg_query(Connection, "INSERT INTO pg_return_delete VALUES (1, 'a'), (2, 'b')", _),
            pg_query(Connection,
                     "DELETE FROM pg_return_delete WHERE id = 2 RETURNING id",
                     Result),
            assertion(Result = data([_], [[2]]))
        )
    ).

test(transaction_rollback_on_exception) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_tx_test(id int)", _),
            catch(
                pg_transaction(Connection,
                    (
                        pg_query(Connection, "INSERT INTO pg_tx_test VALUES (1)", _),
                        throw(test_abort)
                    )),
                test_abort,
                true
            ),
            pg_query(Connection, "SELECT count(*) AS n FROM pg_tx_test", Result),
            assertion(Result = data([_], [[0]]))
        )
    ).

test(transaction_commit_failure_throws_and_rolls_back) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection,
                     "CREATE TEMP TABLE pg_tx_commit_fail(id int UNIQUE DEFERRABLE INITIALLY DEFERRED)",
                     _),
            catch(
                pg_transaction(Connection,
                    (
                        pg_query(Connection, "INSERT INTO pg_tx_commit_fail VALUES (1)", _),
                        pg_query(Connection, "INSERT INTO pg_tx_commit_fail VALUES (1)", _)
                    )),
                Error,
                true
            ),
            assertion(Error = error(pg_transaction_commit(_), _)),
            pg_query(Connection, "SELECT count(*) AS n FROM pg_tx_commit_fail", Result),
            assertion(Result = data([_], [[0]]))
        )
    ).

test(disconnect_cleans_prepared_state) :-
    setup_call_cleanup(
        connect_test_db(Connection),
        once((
            Connection = pg_conn(Stream, _, _, _, _, _),
            pg_prepare(Connection, cleanup_stmt, "SELECT 1 AS n", []),
            assertion(pg_prepared:prepared_statement(Stream, cleanup_stmt, []))
        )),
        pg_disconnect(Connection)
    ),
    assertion(\+ pg_prepared:prepared_statement(_, _, _)).

test(command_complete) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_make_test(id int)", Result),
            assertion(Result == ok("CREATE TABLE"))
        )
    ).

test(create_insert_select) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_make_rows(id int, name text)", _),
            pg_query(Connection, "INSERT INTO pg_make_rows VALUES (1, 'alpha')", InsertResult),
            assertion(InsertResult == ok("INSERT 0 1")),
            pg_query(Connection, "SELECT id, name FROM pg_make_rows", SelectResult),
            assertion(SelectResult = data(_, [[1, "alpha"]]))
        )
    ).

test(syntax_error_returns_error) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "SELECT FROM", Result),
            assertion(Result = error(_))
        )
    ).

test(simple_query_recovery_after_error) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "SELECT FROM", ErrorResult),
            assertion(ErrorResult = error(_)),
            pg_query(Connection, "SELECT 1 AS n", Result),
            assertion(Result = data([_], [[1]]))
        )
    ).

test(simple_query_multi_statement_returns_last_result) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "SELECT 1 AS n; SELECT 2 AS n", Result),
            assertion(Result = data([_], [[2]]))
        )
    ).

test(simple_query_select_then_insert_returns_command_tag) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_multi_insert(id int)", _),
            pg_query(Connection,
                     "SELECT 1 AS n; INSERT INTO pg_multi_insert VALUES (1)",
                     Result),
            assertion(Result == ok("INSERT 0 1"))
        )
    ).

test(simple_query_create_then_select_returns_rows) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection,
                     "CREATE TEMP TABLE pg_multi_select(id int); SELECT 1 AS n",
                     Result),
            assertion(Result = data([_], [[1]]))
        )
    ).

test(simple_query_select_then_error_returns_error) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "SELECT 1 AS n; SELECT FROM", Result),
            assertion(Result = error(_))
        )
    ).

test(prepare_recovery_after_parse_error) :-
    with_connection(
        [Connection]>>(
            catch(
                pg_prepare(Connection, broken_stmt, "SELECT FROM", []),
                error(pg_prepare_error(_), _),
                true
            ),
            pg_query(Connection, "SELECT 1 AS n", Result),
            assertion(Result = data([_], [[1]]))
        )
    ).

test(execute_recovery_after_bind_error) :-
    with_connection(
        [Connection]>>(
            pg_prepare(Connection, int_stmt, "SELECT CAST($1 AS int) AS n", [text]),
            pg_execute(Connection, int_stmt, ["alpha"], ErrorResult),
            assertion(ErrorResult = error(_)),
            pg_query(Connection, "SELECT 1 AS n", Result),
            assertion(Result = data([_], [[1]]))
        )
    ).

test(connection_metadata_api) :-
    with_connection(
        [Connection]>>(
            pg_backend_pid(Connection, PID),
            assertion(integer(PID)),
            assertion(PID > 0),
            pg_server_parameter(Connection, server_version, ServerVersion),
            assertion(string(ServerVersion)),
            pg_server_parameter(Connection, client_encoding, ClientEncoding),
            assertion(ClientEncoding == "UTF8"),
            pg_query(Connection, "SELECT 1", _),
            pg_last_command_tag(Connection, Tag),
            assertion(Tag == "SELECT 1")
        )
    ).

test(non_ascii_roundtrip_utf8_contract) :-
    with_connection(
        [Connection]>>(
            Value = "Привет, こんにちは",
            pg_query(Connection,
                     "SELECT $1::text AS echoed, 'ёж'::text AS literal",
                     [Value],
                     Result),
            assertion(Result = data([_, _], [[Value, "ёж"]]))
        )
    ).

test(copy_from_text) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_copy_text(id int, value text)", _),
            pg_copy_from(Connection,
                         "COPY pg_copy_text (id, value) FROM STDIN WITH (FORMAT text)",
                         chunks([
                             "10\thello world\n",
                             "11\t\\N\n",
                             "12\tline 12\n"
                         ])),
            pg_query(Connection,
                     "SELECT id, value FROM pg_copy_text ORDER BY id",
                     Result),
            assertion(Result = data([_, _],
                                    [[10, "hello world"],
                                     [11, null],
                                     [12, "line 12"]]))
        )
    ).

test(copy_from_csv) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_copy_csv(id int, value text)", _),
            pg_copy_from(Connection,
                         "COPY pg_copy_csv (id, value) FROM STDIN WITH (FORMAT csv, QUOTE '''')",
                         [
                             "20,'hello world'\n",
                             "21,\n",
                             "22,'line 22'\n"
                         ]),
            pg_query(Connection,
                     "SELECT id, value FROM pg_copy_csv ORDER BY id",
                     Result),
            assertion(Result = data([_, _],
                                    [[20, "hello world"],
                                     [21, null],
                                     [22, "line 22"]]))
        )
    ).

test(copy_from_text_utf8_roundtrip) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_copy_utf8(id int, value text)", _),
            pg_copy_from(Connection,
                         "COPY pg_copy_utf8 (id, value) FROM STDIN WITH (FORMAT text)",
                         chunks([
                             "30\tПривет\n",
                             "31\tこんにちは\n",
                             "32\tёж\n"
                         ])),
            pg_query(Connection,
                     "SELECT id, value FROM pg_copy_utf8 ORDER BY id",
                     Result),
            assertion(Result = data([_, _],
                                    [[30, "Привет"],
                                     [31, "こんにちは"],
                                     [32, "ёж"]]))
        )
    ).

test(copy_from_missing_table_reports_error) :-
    with_connection(
        [Connection]>>(
            catch(
                pg_copy_from(Connection,
                             "COPY pg_missing_table (id, value) FROM STDIN WITH (FORMAT text)",
                             "1\talpha\n"),
                Error,
                true
            ),
            assertion(Error = error(pg_copy_error(_, _), _))
        )
    ).

test(copy_from_recovery_after_server_data_error) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_copy_recovery(id int, value text)", _),
            catch(
                pg_copy_from(Connection,
                             "COPY pg_copy_recovery (id, value) FROM STDIN WITH (FORMAT text)",
                             chunks([
                                 "1\talpha\n",
                                 "broken-id\tbeta\n",
                                 "3\tgamma\n"
                             ])),
                Error,
                true
            ),
            assertion(Error = error(pg_copy_error(_, _), _)),
            pg_query(Connection, "SELECT 1 AS n", Result),
            assertion(Result = data([_], [[1]]))
        )
    ).

test(copy_from_binary_format_recovery) :-
    with_connection(
        [Connection]>>(
            pg_query(Connection, "CREATE TEMP TABLE pg_copy_binary(id int, value text)", _),
            catch(
                pg_copy_from(Connection,
                             "COPY pg_copy_binary (id, value) FROM STDIN WITH (FORMAT binary)",
                             "1\talpha\n"),
                Error,
                true
            ),
            assertion(Error = error(not_implemented(copy_format(_)), _)),
            pg_query(Connection, "SELECT 1 AS n", Result),
            assertion(Result = data([_], [[1]]))
        )
    ).

test(copy_from_recovery_after_unexpected_start_response) :-
    with_connection(
        [Connection]>>(
            catch(
                pg_copy_from(Connection,
                             "SELECT 1 AS n",
                             "1\talpha\n"),
                Error,
                true
            ),
            assertion(Error = error(protocol_error(unexpected_copy_start_message(_)), _)),
            pg_query(Connection, "SELECT 1 AS n", Result),
            assertion(Result = data([_], [[1]]))
        )
    ).

test(cancel_query) :-
    thread_self(Parent),
    thread_create(
        (   setup_call_cleanup(
                connect_test_db(Connection),
                (   thread_send_message(Parent, connection(Connection)),
                    pg_query(Connection, "SELECT pg_sleep(5)", Result),
                    thread_send_message(Parent, query_result(Result))
                ),
                pg_disconnect(Connection)
            )
        ),
        ThreadId,
        []
    ),
    thread_get_message(connection(Connection)),
    sleep(0.5),
    pg_cancel(Connection),
    thread_get_message(query_result(Result)),
    thread_join(ThreadId, _),
    assertion(Result = error(Fields)),
    assertion(member(67-"57014", Fields)).

:- end_tests(pg_driver).

run_all_tests :-
    run_tests([pg_driver]).

startup_message_parameters(Bytes, Parameters) :-
    Bytes = [_Len3, _Len2, _Len1, _Len0,
             _V3, _V2, _V1, _V0
            | ParameterBytes],
    startup_parameter_pairs(ParameterBytes, Parameters).

startup_parameter_pairs([0], []) :- !.
startup_parameter_pairs(Bytes, [Key-Value|Pairs]) :-
    split_at_null(Bytes, KeyBytes, Rest1),
    split_at_null(Rest1, ValueBytes, Rest2),
    bytes_text(KeyBytes, Key),
    bytes_text(ValueBytes, Value),
    startup_parameter_pairs(Rest2, Pairs).

split_at_null(Bytes, Before, After) :-
    append(Before, [0|After], Bytes),
    !.
