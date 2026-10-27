-- =====================================================================
--  04_generate.sql : attribute generators + public API
--  Every attribute generator is a small function of (key prefix, inputs);
--  fk.generate_range() wires them together.
-- =====================================================================
CREATE TYPE fk.name_parts AS (first_name text, last_name text, full_name text);

-- 'M' or 'F' with equal probability.
CREATE FUNCTION fk.gen_gender(p_prefix text)
RETURNS char LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN fk.u(p_prefix, 'gender') < 0.5 THEN 'M' ELSE 'F' END::char
$$;

-- Street name: base word + type, glued in German ("Linden"+"straße"),
-- separated by a blank in English ("Oak"+"Street").
CREATE FUNCTION fk.gen_street(p_base text, p_type text, p_type_extra text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_base || CASE WHEN p_type_extra = 'glued' THEN p_type ELSE ' ' || p_type END
$$;

-- Phone number: digits of the (weighted) format mask are filled from the hash.
CREATE FUNCTION fk.gen_phone(p_prefix text, p_pattern text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT fk.fill_pattern(p_pattern, p_prefix, 'phone')
$$;

-- E-mail address from a local-part pattern, the (transliterated) name parts
-- and a domain.  Tokens: {first} {last} {f} {l} {nn} {yy}.
CREATE FUNCTION fk.gen_email(p_prefix text, p_pattern text, p_domain text, p_first text, p_last text,
                             p_src text[] DEFAULT '{}', p_dst text[] DEFAULT '{}')
RETURNS text LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    v_f text := fk.slugify(p_first, p_src, p_dst);
    v_l text := fk.slugify(p_last,  p_src, p_dst);
BEGIN
    RETURN fk.render(p_pattern, ARRAY['first','last','f','l','nn','yy'],
                     ARRAY[v_f, v_l, left(v_f, 1), left(v_l, 1),
                           fk.rand_digits(p_prefix, 'nn', 2),
                           (1960 + fk.rand_int(p_prefix, 'yy', 0, 45))::text])
           || '@' || p_domain;
END $$;

-- Height (cm) and weight (kg): normal distributions.
-- Weight is correlated with height (rho = 0.5):
--    zw = rho * zh + sqrt(1 - rho^2) * z2        (zw is still exactly N(0,1))
-- values are cut at +-4 sigma and rounded to 0.1.
CREATE FUNCTION fk.gen_body(p_prefix text,
                            p_height_mean double precision, p_height_sd double precision,
                            p_weight_mean double precision, p_weight_sd double precision,
                            OUT height_cm numeric, OUT weight_kg numeric)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    zh double precision := fk.rand_normal(p_prefix, 'height', 0, 1);
    zw double precision := 0.5 * zh + sqrt(0.75) * fk.rand_normal(p_prefix, 'weight', 0, 1);
BEGIN
    height_cm := round((p_height_mean + p_height_sd * greatest(-4, least(4, zh)))::numeric, 1);
    weight_kg := round((p_weight_mean + p_weight_sd * greatest(-4, least(4, zw)))::numeric, 1);
END $$;

-- Generates users with in-batch index first_idx .. first_idx + count - 1.
-- Pools are loaded once per call, then every user is produced from its own
-- key prefix, so a user never depends on the others.
CREATE FUNCTION fk.generate_range(p_locale text, p_seed bigint, p_batch integer,
                                  p_first_idx integer, p_count integer, p_batch_size integer DEFAULT 10)
RETURNS SETOF fk.fake_user LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE
    cfg      fk.locales%ROWTYPE;
    bs_m     fk.body_stats%ROWTYPE;
    bs_f     fk.body_stats%ROWTYPE;
    tr_src   text[];  tr_dst text[];
    pl_first_m fk.pool := fk.get_pool(p_locale, 'first', 'M');
    pl_first_f fk.pool := fk.get_pool(p_locale, 'first', 'F');
    pl_last    fk.pool := fk.get_pool(p_locale, 'last',  'U');
    pl_title_m fk.pool := fk.get_pool(p_locale, 'title', 'M');
    pl_title_f fk.pool := fk.get_pool(p_locale, 'title', 'F');
    pl_namepat fk.pool := fk.get_pool(p_locale, 'name_pattern');
    pl_addrpat fk.pool := fk.get_pool(p_locale, 'address_pattern');
    pl_sbase   fk.pool := fk.get_pool(p_locale, 'street_base');
    pl_stype   fk.pool := fk.get_pool(p_locale, 'street_type');
    pl_city    fk.pool := fk.get_pool(p_locale, 'city');
    pl_phone   fk.pool := fk.get_pool(p_locale, 'phone_pattern');
    pl_mailpat fk.pool := fk.get_pool(p_locale, 'email_pattern');
    pl_domain  fk.pool := fk.get_pool(p_locale, 'email_domain');
    pl_eye     fk.pool := fk.get_pool(p_locale, 'eye_color');
    px       text;
    u        fk.fake_user;
    ix       integer;
    first_n  text;  last_n text;  middle text;  last2 text;  title text;
    npat     text;  apat text;
    street   text;  city text;    region text;  num integer;
    sp       record;  bd record;
BEGIN
    SELECT * INTO cfg  FROM fk.locales WHERE code = p_locale;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown locale %', p_locale; END IF;
    SELECT * INTO bs_m FROM fk.body_stats WHERE locale = p_locale AND gender = 'M';
    SELECT * INTO bs_f FROM fk.body_stats WHERE locale = p_locale AND gender = 'F';
    SELECT coalesce(array_agg(src), '{}'), coalesce(array_agg(dst), '{}') INTO tr_src, tr_dst
      FROM fk.translit WHERE locale = p_locale;

    FOR idx IN p_first_idx .. p_first_idx + p_count - 1 LOOP
        px := fk.key_prefix(p_locale, p_seed, p_batch, idx);
        u.seq    := p_batch::bigint * p_batch_size + idx + 1;
        u.gender := fk.gen_gender(px);

        -- ---- name -------------------------------------------------------
        npat := pl_namepat.vals[fk.pick_idx(pl_namepat.cum, fk.u(px, 'namepat'))];
        IF u.gender = 'M' THEN
            ix := fk.pick_idx(pl_first_m.cum, fk.u(px, 'first'));  first_n := pl_first_m.vals[ix];
        ELSE
            ix := fk.pick_idx(pl_first_f.cum, fk.u(px, 'first'));  first_n := pl_first_f.vals[ix];
        END IF;
        last_n := pl_last.vals[fk.pick_idx(pl_last.cum, fk.u(px, 'last'))];
        middle := ''; last2 := ''; title := '';
        IF position('{middle}' IN npat) > 0 OR position('{mi}' IN npat) > 0 THEN
            IF u.gender = 'M' THEN middle := pl_first_m.vals[fk.pick_idx(pl_first_m.cum, fk.u(px, 'middle'))];
            ELSE                   middle := pl_first_f.vals[fk.pick_idx(pl_first_f.cum, fk.u(px, 'middle'))]; END IF;
        END IF;
        IF position('{last2}' IN npat) > 0 THEN
            last2 := pl_last.vals[fk.pick_idx(pl_last.cum, fk.u(px, 'last2'))];
        END IF;
        IF position('{title}' IN npat) > 0 THEN
            IF u.gender = 'M' THEN title := pl_title_m.vals[fk.pick_idx(pl_title_m.cum, fk.u(px, 'title'))];
            ELSE                   title := pl_title_f.vals[fk.pick_idx(pl_title_f.cum, fk.u(px, 'title'))]; END IF;
        END IF;
        u.full_name := fk.render(npat, ARRAY['title','first','middle','mi','last','last2'],
                                       ARRAY[title, first_n, middle, left(middle, 1), last_n, last2]);

        -- ---- address ----------------------------------------------------
        apat := pl_addrpat.vals[fk.pick_idx(pl_addrpat.cum, fk.u(px, 'addrpat'))];
        ix := fk.pick_idx(pl_stype.cum, fk.u(px, 'stype'));
        street := fk.gen_street(pl_sbase.vals[fk.pick_idx(pl_sbase.cum, fk.u(px, 'sbase'))],
                                pl_stype.vals[ix], pl_stype.extras[ix]);
        ix := fk.pick_idx(pl_city.cum, fk.u(px, 'city'));
        city := pl_city.vals[ix];  region := pl_city.extras[ix];
        -- power(u,3) skews towards small numbers: many "12", few "4711"
        num := 1 + floor(power(fk.u(px, 'num'), 3) * cfg.house_number_max)::integer;
        u.address := fk.render(apat, ARRAY['street','num','letter','unit','floor','city','region','zip'],
            ARRAY[street, num::text, chr(97 + fk.rand_int(px, 'letter', 0, 3)),
                  (1 + floor(power(fk.u(px, 'unit'), 2) * 99)::integer)::text,
                  fk.rand_int(px, 'floor', 1, 6)::text, city, region,
                  fk.fill_pattern(cfg.postcode_pattern, px, 'zip')]);

        -- ---- geolocation, body, eyes -----------------------------------
        sp := fk.rand_sphere(px, 'geo');
        u.latitude  := round(sp.latitude::numeric, 6);
        u.longitude := round(sp.longitude::numeric, 6);
        IF u.gender = 'M' THEN
            bd := fk.gen_body(px, bs_m.height_mean, bs_m.height_sd, bs_m.weight_mean, bs_m.weight_sd);
        ELSE
            bd := fk.gen_body(px, bs_f.height_mean, bs_f.height_sd, bs_f.weight_mean, bs_f.weight_sd);
        END IF;
        u.height_cm := bd.height_cm;  u.weight_kg := bd.weight_kg;
        u.eye_color := pl_eye.vals[fk.pick_idx(pl_eye.cum, fk.u(px, 'eye'))];

        -- ---- phone, e-mail ---------------------------------------------
        u.phone := fk.gen_phone(px, pl_phone.vals[fk.pick_idx(pl_phone.cum, fk.u(px, 'phonepat'))]);
        u.email := fk.gen_email(px, pl_mailpat.vals[fk.pick_idx(pl_mailpat.cum, fk.u(px, 'mailpat'))],
                                pl_domain.vals[fk.pick_idx(pl_domain.cum, fk.u(px, 'domain'))],
                                first_n, last_n, tr_src, tr_dst);
        RETURN NEXT u;
    END LOOP;
END $$;

-- PUBLIC API --------------------------------------------------------
-- A batch of users:  SELECT * FROM fk.generate_users('de_DE', 42, 0, 10);
CREATE FUNCTION fk.generate_users(p_locale text, p_seed bigint, p_batch integer, p_size integer DEFAULT 10)
RETURNS SETOF fk.fake_user LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT * FROM fk.generate_range(p_locale, p_seed, p_batch, 0, p_size, p_size)
$$;

-- One user at an exact position (same values as inside the full batch).
CREATE FUNCTION fk.generate_user(p_locale text, p_seed bigint, p_batch integer, p_idx integer, p_batch_size integer DEFAULT 10)
RETURNS fk.fake_user LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT g FROM fk.generate_range(p_locale, p_seed, p_batch, p_idx, 1, p_batch_size) g
$$;

-- Throughput measurement:  SELECT * FROM fk.benchmark('en_US', 1, 100000);
CREATE FUNCTION fk.benchmark(p_locale text, p_seed bigint, p_total integer, p_batch_size integer DEFAULT 1000)
RETURNS TABLE (users integer, seconds numeric, users_per_second numeric)
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); n integer;
BEGIN
    SELECT count(*) INTO n FROM generate_series(0, (p_total - 1) / p_batch_size) AS b,
         LATERAL fk.generate_users(p_locale, p_seed, b, p_batch_size) AS g
    WHERE g.seq <= p_total;
    users := n;
    seconds := round(extract(epoch FROM clock_timestamp() - t0)::numeric, 3);
    users_per_second := round(n / greatest(seconds, 0.001), 0);
    RETURN NEXT;
END $$;
