CREATE TABLE IF NOT EXISTS schema_version (
    version text NOT NULL
);

TRUNCATE TABLE schema_version;
INSERT INTO schema_version(version) VALUES ('1');

CREATE TABLE IF NOT EXISTS pg_items (
    id integer PRIMARY KEY,
    name text NOT NULL,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pg_copy_items (
    id integer PRIMARY KEY,
    name text,
    note text
);

CREATE TABLE IF NOT EXISTS pg_type_samples (
    id integer PRIMARY KEY,
    value_text text,
    value_int integer,
    value_bool boolean,
    value_json jsonb
);

TRUNCATE TABLE pg_type_samples;
TRUNCATE TABLE pg_copy_items;
TRUNCATE TABLE pg_items;

INSERT INTO pg_items(id, name, active) VALUES
    (1, 'alpha', true),
    (2, 'beta', false);
