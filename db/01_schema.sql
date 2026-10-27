-- =====================================================================
--  FakeSQL : a "Faker" implemented in PostgreSQL stored routines
--  01_schema.sql : schema, lookup tables, composite types
--  Idempotent: safe to run again (drops and recreates the schema).
-- =====================================================================
-- unaccent: standard PostgreSQL extension, strips accents for e-mail addresses
CREATE EXTENSION IF NOT EXISTS unaccent;

DROP SCHEMA IF EXISTS fk CASCADE;
CREATE SCHEMA fk;

-- One row per supported locale.  Adding a locale = adding rows (see docs).
CREATE TABLE fk.locales (
    code             text PRIMARY KEY,           -- 'en_US', 'de_DE', ...
    title            text NOT NULL,              -- shown in the UI
    postcode_pattern text NOT NULL DEFAULT '#####',  -- N = digit 2-9, # = digit 0-9
    house_number_max integer NOT NULL DEFAULT 999    -- upper bound of generated house numbers
);

-- Special-character replacements used when building e-mail addresses
-- (e.g. German "ü" -> "ue").  Anything not listed falls back to plain
-- accent stripping in fk.slugify().
CREATE TABLE fk.translit (
    locale  text NOT NULL REFERENCES fk.locales,
    src     text NOT NULL,
    dst     text NOT NULL,
    PRIMARY KEY (locale, src)
);

-- All person names of all locales in ONE table.
--   kind   : 'first' | 'last'
--   gender : 'M' | 'F' for first names, 'U' (unisex/any) for last names
--   weight : relative frequency (any positive number)
CREATE TABLE fk.names (
    id      bigserial PRIMARY KEY,
    locale  text NOT NULL REFERENCES fk.locales,
    kind    text NOT NULL CHECK (kind IN ('first','last')),
    gender  char(1) NOT NULL CHECK (gender IN ('M','F','U')),
    value   text NOT NULL,
    weight  double precision NOT NULL DEFAULT 1 CHECK (weight > 0)
);

-- Every other word list / pattern list, again with a locale column.
--   kind (examples): title, street_base, street_type, city, email_domain,
--                    eye_color, name_pattern, address_pattern,
--                    phone_pattern, email_pattern
--   sub   : sub-category (gender for titles, '' otherwise)
--   extra : kind-specific payload (city -> region, street_type -> 'glued')
CREATE TABLE fk.lexicon (
    id      bigserial PRIMARY KEY,
    locale  text NOT NULL REFERENCES fk.locales,
    kind    text NOT NULL,
    sub     text NOT NULL DEFAULT '',
    value   text NOT NULL,
    extra   text NOT NULL DEFAULT '',
    weight  double precision NOT NULL DEFAULT 1 CHECK (weight > 0)
);

-- Pre-computed weighted pools: one row per (locale, kind, sub) holding the
-- values and the cumulative distribution as arrays.  Built by
-- fk.refresh_pools() from fk.names + fk.lexicon.  A weighted pick is then a
-- binary search in `cum` (see fk.pick_idx) with no table access at all.
CREATE TABLE fk.pools (
    locale  text NOT NULL,
    kind    text NOT NULL,
    sub     text NOT NULL,
    vals    text[]             NOT NULL,
    extras  text[]             NOT NULL,
    cum     double precision[] NOT NULL,
    PRIMARY KEY (locale, kind, sub)
);
CREATE TYPE fk.pool AS (vals text[], extras text[], cum double precision[]);

-- Normal-distribution parameters of physical attributes per locale / gender.
CREATE TABLE fk.body_stats (
    locale       text NOT NULL REFERENCES fk.locales,
    gender       char(1) NOT NULL CHECK (gender IN ('M','F')),
    height_mean  double precision NOT NULL,   -- cm
    height_sd    double precision NOT NULL,
    weight_mean  double precision NOT NULL,   -- kg
    weight_sd    double precision NOT NULL,
    PRIMARY KEY (locale, gender)
);

-- Result row of every generator.
CREATE TYPE fk.fake_user AS (
    seq         bigint,             -- running number inside (locale, seed): batch*size + idx + 1
    full_name   text,
    gender      char(1),
    address     text,
    latitude    double precision,
    longitude   double precision,
    height_cm   integer,            -- whole centimetres
    weight_kg   integer,            -- whole kilograms
    eye_color   text,
    phone       text,
    email       text
);

