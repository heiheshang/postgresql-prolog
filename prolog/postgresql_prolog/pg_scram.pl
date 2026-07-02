:- module(pg_scram, [
    scram_client_first_bare/3,        % +Username, +ClientNonce, -ClientFirstBare
    scram_client_first_message/2,     % +ClientFirstBare, -ClientFirstMessage
    scram_parse_server_first/4,       % +ServerFirst, -Nonce, -SaltBytes, -Iterations
    scram_client_final_without_proof/2,% +CombinedNonce, -ClientFinalWithoutProof
    scram_auth_message/4,             % +ClientFirstBare, +ServerFirst, +ClientFinalNoProof, -AuthMessage
    scram_salted_password/4,          % +Password, +SaltBytes, +Iterations, -SaltedPassword
    scram_client_proof/3,             % +SaltedPassword, +AuthMessage, -ClientProofBytes
    scram_client_final_message/3,     % +ClientFinalNoProof, +ClientProofBytes, -ClientFinalMessage
    scram_server_signature/3,         % +SaltedPassword, +AuthMessage, -ServerSignatureBytes
    scram_parse_server_final/2,       % +ServerFinal, -ServerSignatureBytes
    scram_base64_encode/2,            % +Bytes, -Base64
    scram_base64_decode/2             % +Base64, -Bytes
]).

:- use_module(library(crypto)).
:- use_module(library(base64)).
:- use_module(library(lists)).
:- use_module(library(error)).

/** <module> SCRAM-SHA-256 primitives for PostgreSQL SASL authentication.

This is a pure module: it builds and parses SCRAM messages and computes the
cryptographic proofs, without performing any stream I/O. Client-nonce
generation and the message exchange loop live in `pg_auth.pl`.

Only SCRAM-SHA-256 without channel binding is implemented, so the gs2 header
is always `n,,` and the client-final channel-binding field is the fixed
base64 value `biws` (base64 of `n,,`).
*/

scram_client_first_bare(Username, ClientNonce, ClientFirstBare) :-
    scram_escape_username(Username, EscapedUser),
    format(string(ClientFirstBare), "n=~w,r=~w", [EscapedUser, ClientNonce]).

scram_client_first_message(ClientFirstBare, ClientFirstMessage) :-
    string_concat("n,,", ClientFirstBare, ClientFirstMessage).

scram_client_final_without_proof(CombinedNonce, ClientFinalWithoutProof) :-
    format(string(ClientFinalWithoutProof), "c=biws,r=~w", [CombinedNonce]).

scram_client_final_message(ClientFinalNoProof, ClientProofBytes, ClientFinalMessage) :-
    scram_base64_encode(ClientProofBytes, ProofBase64),
    format(string(ClientFinalMessage), "~w,p=~w", [ClientFinalNoProof, ProofBase64]).

scram_auth_message(ClientFirstBare, ServerFirst, ClientFinalNoProof, AuthMessage) :-
    format(string(AuthMessage), "~w,~w,~w",
           [ClientFirstBare, ServerFirst, ClientFinalNoProof]).

scram_parse_server_first(ServerFirst, Nonce, SaltBytes, Iterations) :-
    scram_server_first_fields(ServerFirst, Nonce, SaltBase64, IterationsString),
    scram_base64_decode(SaltBase64, SaltBytes),
    number_string(Iterations, IterationsString).

scram_server_first_fields(ServerFirst, Nonce, SaltBase64, IterationsString) :-
    split_string(ServerFirst, ",", "", [NonceField, SaltField, IterationsField|_]),
    scram_field_value(NonceField, "r", Nonce),
    scram_field_value(SaltField, "s", SaltBase64),
    scram_field_value(IterationsField, "i", IterationsString).

scram_parse_server_final(ServerFinal, ServerSignatureBytes) :-
    scram_field_value(ServerFinal, "v", SignatureBase64),
    scram_base64_decode(SignatureBase64, ServerSignatureBytes).

scram_field_value(Field, Key, Value) :-
    string_concat(Key, "=", Prefix),
    string_concat(Prefix, Value, Field).

scram_salted_password(Password, SaltBytes, Iterations, SaltedPassword) :-
    scram_text_bytes(Password, PasswordBytes),
    pbkdf2_hmac_sha256(PasswordBytes, SaltBytes, Iterations, SaltedPassword).

scram_client_proof(SaltedPassword, AuthMessage, ClientProof) :-
    scram_text_bytes(AuthMessage, AuthMessageBytes),
    scram_client_key(SaltedPassword, ClientKey),
    sha256_bytes(ClientKey, StoredKey),
    hmac_sha256(StoredKey, AuthMessageBytes, ClientSignature),
    bytes_xor(ClientKey, ClientSignature, ClientProof).

scram_server_signature(SaltedPassword, AuthMessage, ServerSignature) :-
    scram_text_bytes(AuthMessage, AuthMessageBytes),
    string_codes("Server Key", ServerKeyData),
    hmac_sha256(SaltedPassword, ServerKeyData, ServerKey),
    hmac_sha256(ServerKey, AuthMessageBytes, ServerSignature).

scram_client_key(SaltedPassword, ClientKey) :-
    string_codes("Client Key", ClientKeyData),
    hmac_sha256(SaltedPassword, ClientKeyData, ClientKey).

pbkdf2_hmac_sha256(Password, Salt, Iterations, DerivedKey) :-
    append(Salt, [0, 0, 0, 1], FirstBlockData),
    hmac_sha256(Password, FirstBlockData, FirstU),
    pbkdf2_accumulate(Password, FirstU, FirstU, Iterations, DerivedKey).

pbkdf2_accumulate(_, _, Accumulator, 1, Accumulator) :- !. % Green cut: iteration 1 already folded in
pbkdf2_accumulate(Password, PreviousU, Accumulator, Remaining, DerivedKey) :-
    Remaining > 1,
    hmac_sha256(Password, PreviousU, NextU),
    bytes_xor(Accumulator, NextU, NextAccumulator),
    Remaining1 is Remaining - 1,
    pbkdf2_accumulate(Password, NextU, NextAccumulator, Remaining1, DerivedKey).

hmac_sha256(Key, Data, Mac) :-
    crypto_data_hash(Data, HexMac, [algorithm(sha256), hmac(Key), encoding(octet)]),
    hex_bytes(HexMac, Mac).

sha256_bytes(Data, Hash) :-
    crypto_data_hash(Data, HexHash, [algorithm(sha256), encoding(octet)]),
    hex_bytes(HexHash, Hash).

bytes_xor([], [], []).
bytes_xor([A|As], [B|Bs], [X|Xs]) :-
    X is A xor B,
    bytes_xor(As, Bs, Xs).

scram_base64_encode(Bytes, Base64) :-
    phrase(base64(Bytes), Base64Codes),
    string_codes(Base64, Base64Codes).

scram_base64_decode(Base64, Bytes) :-
    string_codes(Base64, Base64Codes),
    phrase(base64(Bytes), Base64Codes).

scram_escape_username(Username, Escaped) :-
    scram_text_string(Username, String),
    string_chars(String, Chars),
    scram_escape_chars(Chars, EscapedChars),
    string_chars(Escaped, EscapedChars).

scram_escape_chars([], []).
scram_escape_chars([','|Tail], ['=', '2', 'C'|Escaped]) :-
    !, % Green cut: ',' must always be escaped as =2C
    scram_escape_chars(Tail, Escaped).
scram_escape_chars(['='|Tail], ['=', '3', 'D'|Escaped]) :-
    !, % Green cut: '=' must always be escaped as =3D
    scram_escape_chars(Tail, Escaped).
scram_escape_chars([Char|Tail], [Char|Escaped]) :-
    scram_escape_chars(Tail, Escaped).

scram_text_string(Text, Text) :-
    string(Text),
    !. % Green cut: already a string
scram_text_string(Text, String) :-
    atom(Text),
    !, % Green cut: atom converts deterministically
    atom_string(Text, String).

scram_text_bytes(Text, Bytes) :-
    string(Text),
    !, % Green cut: string path
    string_bytes(Text, Bytes, utf8).
scram_text_bytes(Text, Bytes) :-
    atom(Text),
    !, % Green cut: atom path
    atom_string(Text, String),
    string_bytes(String, Bytes, utf8).
scram_text_bytes(Bytes, Bytes) :-
    is_list(Bytes),
    !. % Green cut: already raw bytes
scram_text_bytes(Text, _) :-
    type_error(text, Text).

:- multifile sandbox:safe_primitive/1.
sandbox:safe_primitive(pg_scram:_).
