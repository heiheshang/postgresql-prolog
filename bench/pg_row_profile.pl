:- module(pg_row_profile, [run/0]).

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(prolog_profile)).
:- use_module(library(statistics)).
:- use_module(library(postgresql_prolog/pg)).

run :-
    profile_config(Config),
    set_prolog_flag(stack_limit, 4_294_967_296),
    print_config(Config),
    setup_call_cleanup(
        connect_test_db(Connection),
        run_profile_pass(Connection, Config),
        pg_disconnect(Connection)
    ).

profile_config(config{
    paths: Paths,
    profile_rows: ProfileRows,
    profile_time: ProfileTime,
    rows: Rows,
    sample_rate: SampleRate,
    scenarios: Scenarios,
    top: Top
}) :-
    default_rows(DefaultRows),
    default_paths(DefaultPaths),
    default_scenarios(DefaultScenarios),
    env_integer_list('PG_PROFILE_ROWS', DefaultRows, Rows),
    env_atom_list('PG_PROFILE_PATHS', DefaultPaths, Paths),
    env_atom_list('PG_PROFILE_SCENARIOS', DefaultScenarios, Scenarios),
    env_atom('PG_PROFILE_TIME', cpu, ProfileTime),
    env_integer('PG_PROFILE_TOP', 12, Top),
    env_integer('PG_PROFILE_SAMPLE_RATE', 400, SampleRate),
    max_list(Rows, MaxRows),
    env_integer('PG_PROFILE_PROFILE_ROWS', MaxRows, ProfileRows).

default_rows([10000, 100000, 300000]).

default_paths([simple, params, prepared]).

default_scenarios([narrow_ints, mixed_types, utf8_text, wide_text, wide_columns]).

scenario_definition(narrow_ints, scenario{
    name: narrow_ints,
    columns: 2,
    simple_sql: "SELECT gs::int4 AS n, (gs * 2)::int8 AS doubled FROM generate_series(1, ~d) AS gs",
    param_sql: "SELECT gs::int4 AS n, (gs * 2)::int8 AS doubled FROM generate_series(1, $1::int) AS gs",
    prepare_name: profile_narrow_ints,
    param_types: [int4]
}).
scenario_definition(mixed_types, scenario{
    name: mixed_types,
    columns: 4,
    simple_sql: "SELECT gs::int4 AS id, (gs % 2 = 0) AS even, ('tag-' || gs)::text AS tag, lpad((gs % 1000)::text, 8, '0')::varchar AS code FROM generate_series(1, ~d) AS gs",
    param_sql: "SELECT gs::int4 AS id, (gs % 2 = 0) AS even, ('tag-' || gs)::text AS tag, lpad((gs % 1000)::text, 8, '0')::varchar AS code FROM generate_series(1, $1::int) AS gs",
    prepare_name: profile_mixed_types,
    param_types: [int4]
}).
scenario_definition(utf8_text, scenario{
    name: utf8_text,
    columns: 2,
    simple_sql: "SELECT gs::int4 AS id, ((CASE gs % 3 WHEN 0 THEN 'Привет' WHEN 1 THEN 'こんにちは' ELSE 'ёжик' END) || '-' || gs)::text AS message FROM generate_series(1, ~d) AS gs",
    param_sql: "SELECT gs::int4 AS id, ((CASE gs % 3 WHEN 0 THEN 'Привет' WHEN 1 THEN 'こんにちは' ELSE 'ёжик' END) || '-' || gs)::text AS message FROM generate_series(1, $1::int) AS gs",
    prepare_name: profile_utf8_text,
    param_types: [int4]
}).
scenario_definition(wide_text, scenario{
    name: wide_text,
    columns: 2,
    simple_sql: "SELECT gs::int4 AS id, repeat(md5(gs::text), 2)::text AS payload FROM generate_series(1, ~d) AS gs",
    param_sql: "SELECT gs::int4 AS id, repeat(md5(gs::text), 2)::text AS payload FROM generate_series(1, $1::int) AS gs",
    prepare_name: profile_wide_text,
    param_types: [int4]
}).
scenario_definition(wide_columns, scenario{
    name: wide_columns,
    columns: 8,
    simple_sql: "SELECT gs::int4 AS c1, (gs + 1)::int4 AS c2, (gs + 2)::int4 AS c3, (gs + 3)::int4 AS c4, ('x' || gs)::text AS c5, ('y' || gs)::text AS c6, (gs % 2 = 0) AS c7, lpad((gs % 10000)::text, 16, '0')::varchar AS c8 FROM generate_series(1, ~d) AS gs",
    param_sql: "SELECT gs::int4 AS c1, (gs + 1)::int4 AS c2, (gs + 2)::int4 AS c3, (gs + 3)::int4 AS c4, ('x' || gs)::text AS c5, ('y' || gs)::text AS c6, (gs % 2 = 0) AS c7, lpad((gs % 10000)::text, 16, '0')::varchar AS c8 FROM generate_series(1, $1::int) AS gs",
    prepare_name: profile_wide_columns,
    param_types: [int4]
}).

print_config(Config) :-
    format("pg_row_profile rows=~w profile_rows=~d time=~w sample_rate=~d top=~d~n",
           [Config.rows, Config.profile_rows, Config.profile_time, Config.sample_rate, Config.top]),
    format("pg_row_profile scenarios=~w~n", [Config.scenarios]),
    format("pg_row_profile paths=~w~n~n", [Config.paths]).

run_profile_pass(Connection, Config) :-
    warm_connection(Connection),
    prepare_selected_statements(Connection, Config.scenarios),
    maplist(run_scenario(Connection, Config), Config.scenarios).

warm_connection(Connection) :-
    pg_query(Connection, "SELECT 1 AS n", Result),
    validate_result(Result, 1, 1).

prepare_selected_statements(_, []).
prepare_selected_statements(Connection, [ScenarioName|ScenarioNames]) :-
    scenario_definition(ScenarioName, Scenario),
    pg_prepare(Connection,
               Scenario.prepare_name,
               Scenario.param_sql,
               Scenario.param_types),
    prepare_selected_statements(Connection, ScenarioNames).

run_scenario(Connection, Config, ScenarioName) :-
    scenario_definition(ScenarioName, Scenario),
    format("=== scenario: ~w ===~n", [ScenarioName]),
    maplist(run_timed_path(Connection, Scenario, Config.paths), Config.rows),
    nl,
    maplist(run_profiled_path(Connection, Scenario, Config), Config.paths),
    nl.

run_timed_path(Connection, Scenario, Paths, Rows) :-
    format("rows=~d~n", [Rows]),
    maplist(run_timed_variant(Connection, Scenario, Rows), Paths),
    nl.

run_timed_variant(Connection, Scenario, Rows, Path) :-
    call_time(run_variant(Connection, Scenario, Path, Rows), Time),
    format("  ~w wall=~3f cpu=~3f inferences=~d~n",
           [Path, Time.wall, Time.cpu, Time.inferences]),
    cleanup_profile_memory.

run_profiled_path(Connection, Scenario, Config, Path) :-
    format("--- profile scenario=~w path=~w rows=~d ---~n",
           [Scenario.name, Path, Config.profile_rows]),
    profile(
        run_variant(Connection, Scenario, Path, Config.profile_rows),
        [ time(Config.profile_time),
          sample_rate(Config.sample_rate),
          top(Config.top),
          cumulative(true)
        ]),
    nl,
    cleanup_profile_memory.

run_variant(Connection, Scenario, simple, Rows) :-
    format(string(SQL), Scenario.simple_sql, [Rows]),
    pg_query(Connection, SQL, Result),
    validate_result(Result, Rows, Scenario.columns).
run_variant(Connection, Scenario, params, Rows) :-
    pg_query(Connection, Scenario.param_sql, [Rows], Result),
    validate_result(Result, Rows, Scenario.columns).
run_variant(Connection, Scenario, prepared, Rows) :-
    pg_execute(Connection, Scenario.prepare_name, [Rows], Result),
    validate_result(Result, Rows, Scenario.columns).

validate_result(data(Columns, Rows), ExpectedRows, MinColumns) :-
    length(Rows, ExpectedRows),
    length(Columns, ColumnCount),
    ColumnCount >= MinColumns,
    !.
validate_result(Result, _, _) :-
    throw(error(unexpected_profile_result(Result), _)).

connect_test_db(Connection) :-
    connection_options(Host, Port, Options),
    pg_connect(Host:Port, Connection, Options).

connection_options(Host, Port, Options) :-
    env_string('PGHOST', "127.0.0.1", HostString),
    atom_string(Host, HostString),
    env_string('PGPORT', "5432", PortString),
    number_string(Port, PortString),
    env_string('PGUSER', "postgres", User),
    env_string('PGDATABASE', "postgres", Database),
    BaseOptions = [user(User), database(Database)],
    (   getenv('PGPASSWORD', Password),
        Password \== ''
    ->  Options = [password(Password)|BaseOptions]
    ;   Options = BaseOptions
    ).

env_string(Name, Default, Value) :-
    (   getenv(Name, Raw),
        Raw \== ''
    ->  env_value_string(Raw, Value)
    ;   Value = Default
    ).

env_atom(Name, Default, Value) :-
    env_string(Name, "", Raw),
    (   Raw == ""
    ->  Value = Default
    ;   string_lower(Raw, Lower),
        atom_string(Value, Lower)
    ).

env_integer(Name, Default, Value) :-
    env_string(Name, "", Raw),
    (   Raw == ""
    ->  Value = Default
    ;   number_string(Value, Raw)
    ).

env_atom_list(Name, Default, Values) :-
    env_string(Name, "", Raw),
    (   Raw == ""
    ->  Values = Default
    ;   split_string(Raw, ",", " \t\n", Parts),
        maplist(string_to_lower_atom, Parts, Values)
    ).

env_integer_list(Name, Default, Values) :-
    env_string(Name, "", Raw),
    (   Raw == ""
    ->  Values = Default
    ;   split_string(Raw, ",", " \t\n", Parts),
        maplist(number_string, Values, Parts)
    ).

string_to_lower_atom(String, Atom) :-
    string_lower(String, Lower),
    atom_string(Atom, Lower).

env_value_string(Raw, Value) :-
    (   string(Raw)
    ->  Value = Raw
    ;   atom(Raw)
    ->  atom_string(Raw, Value)
    ;   Value = Raw
    ).

cleanup_profile_memory :-
    garbage_collect,
    trim_stacks.
