:- module(pg_auth, [
    pg_receive_auth/3
]).

:- use_module(library(crypto)).

:- use_module(library(postgresql_prolog/pg_protocol)).

/** <module> PostgreSQL authentication helpers.

Internal authentication layer for the PostgreSQL driver.
This module owns the startup authentication exchange and currently supports
cleartext password and `md5` authentication methods.

It is intended for use by `pg.pl`, not as a standalone public API.
*/

pg_receive_auth(Stream, User, Pass) :-
    read_message(Stream, Msg),
    (   Msg = auth-Bytes
    ->  parse_authentication(Bytes, Method),
        handle_auth_method(Stream, User, Method, Pass, Continue),
        (   Continue == continue
        ->  pg_receive_auth(Stream, User, Pass)
        ;   true
        )
    ;   Msg = error-Bytes
    ->  parse_error_fields(Bytes, Fields),
        throw(error(connection_error(Fields), _))
    ;   throw(error(unexpected_auth_message(Msg), _))
    ).

handle_auth_method(_, _, ok, _, done) :- !.
handle_auth_method(Stream, _, password, Pass, continue) :-
    !,
    password_message(Pass, Msg),
    write_message(Stream, Msg).
handle_auth_method(Stream, User, md5_salt(Salt), Pass, continue) :-
    !,
    md5_password(User, Pass, Salt, Encrypted),
    password_message(Encrypted, Msg),
    write_message(Stream, Msg).
handle_auth_method(_, _, sasl, _, _) :-
    throw(error(unsupported_auth_method(sasl), _)).
handle_auth_method(_, _, sasl_continue(_), _, _) :-
    throw(error(unsupported_auth_method(sasl_continue), _)).
handle_auth_method(_, _, sasl_final(_), _, _) :-
    throw(error(unsupported_auth_method(sasl_final), _)).
handle_auth_method(_, _, Method, _, _) :-
    throw(error(unsupported_auth_method(Method), _)).

md5_password(User, Pass, Salt, Encrypted) :-
    atomics_to_string([Pass, User], '', PassUser),
    crypto_data_hash(PassUser, Hash1, [algorithm(md5), encoding(utf8)]),
    atom_codes(Hash1, Hash1HexCodes),
    append(Hash1HexCodes, Salt, Step2Data),
    crypto_data_hash(Step2Data, Hash2, [algorithm(md5), encoding(octet)]),
    atom_concat(md5, Hash2, Encrypted).
