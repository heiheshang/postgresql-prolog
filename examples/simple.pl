setup_local_pack_path :-
    prolog_load_context(directory, ExampleDir),
    directory_file_path(ExampleDir, '..', RootDir),
    directory_file_path(RootDir, prolog, PrologDir),
    asserta(user:file_search_path(library, PrologDir)).

:- initialization(setup_local_pack_path, now).

:- use_module(library(postgresql_prolog/pg)).

/** <module> Small example for postgresql_prolog.

Run with connection settings from your local PostgreSQL instance.
The example uses the standard libpq environment variables if they are set
and otherwise falls back to a simple localhost/postgres configuration.

==
?- [examples/simple].
?- simple.
==
*/

simple :-
    connection_target(Host, Port, Options),
    setup_call_cleanup(
        pg_connect(Host:Port, Conn, Options),
        run_demo(Conn),
        pg_disconnect(Conn)
    ).

run_demo(Conn) :-
    pg_query(Conn, "SELECT 1 AS n, 'alpha'::text AS label", Result),
    writeln(Result),
    pg_backend_pid(Conn, PID),
    format("backend_pid(~w)~n", [PID]).

connection_target(Host, Port, Options) :-
    env_or_default('PGHOST', '127.0.0.1', HostString),
    atom_string(Host, HostString),
    env_or_default('PGPORT', '5432', PortString),
    atom_number(PortString, Port),
    env_or_default('PGUSER', 'postgres', User),
    env_or_default('PGDATABASE', 'postgres', Database),
    BaseOptions = [user(User), database(Database)],
    (   getenv('PGPASSWORD', Password),
        Password \== ''
    ->  Options = [password(Password)|BaseOptions]
    ;   Options = BaseOptions
    ).

env_or_default(Name, Default, Value) :-
    (   getenv(Name, Raw),
        Raw \== ''
    ->  Value = Raw
    ;   Value = Default
    ).
