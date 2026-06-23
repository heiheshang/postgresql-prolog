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
        [Connection]>>assertion(Connection = pg_conn(_, _, _, _))
    ).

test(startup_message_sets_client_encoding_utf8) :-
    startup_message("alice", "example_db", Bytes),
    startup_message_parameters(Bytes, Parameters),
    assertion(member("user"-"alice", Parameters)),
    assertion(member("database"-"example_db", Parameters)),
    assertion(member("client_encoding"-"UTF8", Parameters)).

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
