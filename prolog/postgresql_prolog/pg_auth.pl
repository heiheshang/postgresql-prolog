:- module(pg_auth, [
    pg_receive_auth/3
]).

:- use_module(library(crypto)).
:- use_module(library(lists)).

:- use_module(library(postgresql_prolog/pg_protocol)).
:- use_module(library(postgresql_prolog/pg_scram)).

/** <module> PostgreSQL authentication helpers.

Internal authentication layer for the PostgreSQL driver.
This module owns the startup authentication exchange and supports cleartext
password, `md5`, and SCRAM-SHA-256 (SASL) authentication methods.

SCRAM-SHA-256 is implemented without channel binding, so the
`SCRAM-SHA-256-PLUS` mechanism is never selected. Channel binding is deferred
until TLS support is available.

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
handle_auth_method(Stream, _, sasl(Mechanisms), Pass, continue) :-
    !,
    scram_authenticate(Stream, Pass, Mechanisms).
handle_auth_method(_, _, Method, _, _) :-
    throw(error(unsupported_auth_method(Method), _)).

md5_password(User, Pass, Salt, Encrypted) :-
    atomics_to_string([Pass, User], '', PassUser),
    crypto_data_hash(PassUser, Hash1, [algorithm(md5), encoding(utf8)]),
    atom_codes(Hash1, Hash1HexCodes),
    append(Hash1HexCodes, Salt, Step2Data),
    crypto_data_hash(Step2Data, Hash2, [algorithm(md5), encoding(octet)]),
    atom_concat(md5, Hash2, Encrypted).

scram_authenticate(Stream, Password, Mechanisms) :-
    scram_select_mechanism(Mechanisms, Mechanism),
    scram_generate_nonce(ClientNonce),
    scram_client_first_bare("", ClientNonce, ClientFirstBare),
    scram_send_client_first(Stream, Mechanism, ClientFirstBare),
    scram_complete_exchange(Stream, Password, ClientNonce, ClientFirstBare).

scram_select_mechanism(Mechanisms, "SCRAM-SHA-256") :-
    memberchk("SCRAM-SHA-256", Mechanisms),
    !. % Green cut: plain SCRAM-SHA-256 selected, channel binding unsupported
scram_select_mechanism(Mechanisms, _) :-
    throw(error(pg_auth_error(scram_mechanism_unsupported(Mechanisms)), _)).

scram_generate_nonce(ClientNonce) :-
    crypto_n_random_bytes(18, RandomBytes),
    scram_base64_encode(RandomBytes, ClientNonce).

scram_send_client_first(Stream, Mechanism, ClientFirstBare) :-
    scram_client_first_message(ClientFirstBare, ClientFirstMessage),
    string_bytes(ClientFirstMessage, ClientFirstBytes, utf8),
    sasl_initial_response(Mechanism, ClientFirstBytes, Message),
    write_message(Stream, Message).

scram_complete_exchange(Stream, Password, ClientNonce, ClientFirstBare) :-
    scram_read_server_first(Stream, ServerFirst),
    scram_derive_client_final(Password, ClientNonce, ClientFirstBare, ServerFirst,
                              ClientFinalMessage, ExpectedServerSignature),
    scram_send_client_final(Stream, ClientFinalMessage),
    scram_read_verify_server_final(Stream, ExpectedServerSignature).

scram_derive_client_final(Password, ClientNonce, ClientFirstBare, ServerFirst,
                          ClientFinalMessage, ExpectedServerSignature) :-
    scram_parse_server_first(ServerFirst, CombinedNonce, Salt, Iterations),
    scram_verify_nonce(ClientNonce, CombinedNonce),
    scram_salted_password(Password, Salt, Iterations, SaltedPassword),
    scram_build_client_final(SaltedPassword, ClientFirstBare, ServerFirst, CombinedNonce,
                             ClientFinalMessage, AuthMessage),
    scram_server_signature(SaltedPassword, AuthMessage, ExpectedServerSignature).

scram_build_client_final(SaltedPassword, ClientFirstBare, ServerFirst, CombinedNonce,
                         ClientFinalMessage, AuthMessage) :-
    scram_client_final_without_proof(CombinedNonce, ClientFinalWithoutProof),
    scram_auth_message(ClientFirstBare, ServerFirst, ClientFinalWithoutProof, AuthMessage),
    scram_client_proof(SaltedPassword, AuthMessage, ClientProof),
    scram_client_final_message(ClientFinalWithoutProof, ClientProof, ClientFinalMessage).

scram_verify_nonce(ClientNonce, CombinedNonce) :-
    string_concat(ClientNonce, _, CombinedNonce),
    !. % Green cut: combined nonce starts with the client nonce
scram_verify_nonce(ClientNonce, CombinedNonce) :-
    throw(error(pg_auth_error(scram_nonce_mismatch(ClientNonce, CombinedNonce)), _)).

scram_send_client_final(Stream, ClientFinalMessage) :-
    string_bytes(ClientFinalMessage, ClientFinalBytes, utf8),
    sasl_response(ClientFinalBytes, Message),
    write_message(Stream, Message).

scram_read_server_first(Stream, ServerFirst) :-
    scram_read_auth(Stream, Method),
    scram_server_first_text(Method, ServerFirst).

scram_server_first_text(sasl_continue(Payload), ServerFirst) :-
    !,
    bytes_text(Payload, ServerFirst).
scram_server_first_text(Method, _) :-
    throw(error(pg_auth_error(unexpected_sasl_continue(Method)), _)).

scram_read_verify_server_final(Stream, ExpectedServerSignature) :-
    scram_read_auth(Stream, Method),
    scram_verify_server_final(Method, ExpectedServerSignature).

scram_verify_server_final(sasl_final(Payload), ExpectedServerSignature) :-
    !,
    bytes_text(Payload, ServerFinal),
    scram_parse_server_final(ServerFinal, ServerSignature),
    scram_match_server_signature(ServerSignature, ExpectedServerSignature).
scram_verify_server_final(Method, _) :-
    throw(error(pg_auth_error(unexpected_sasl_final(Method)), _)).

scram_match_server_signature(Signature, Signature) :-
    !. % Green cut: server signature verified
scram_match_server_signature(_, _) :-
    throw(error(pg_auth_error(scram_server_signature_mismatch), _)).

scram_read_auth(Stream, Method) :-
    read_message(Stream, Msg),
    scram_auth_from_message(Msg, Method).

scram_auth_from_message(auth-Bytes, Method) :-
    !,
    parse_authentication(Bytes, Method).
scram_auth_from_message(error-Bytes, _) :-
    !,
    parse_error_fields(Bytes, Fields),
    throw(error(connection_error(Fields), _)).
scram_auth_from_message(Msg, _) :-
    throw(error(pg_auth_error(unexpected_auth_message(Msg)), _)).
