-- =====================================================================
--  03_text.sql : pools, weighted picking and string helpers
-- =====================================================================

-- Rebuilds fk.pools from fk.names and fk.lexicon.  Run after loading data.
-- cum[i] = (w1 + ... + wi) / (w1 + ... + wn)   -> non-decreasing, last = 1.
-- Pool keys:  names -> kind 'first' / 'last' (sub = gender),
--             lexicon rows keep their own (kind, sub).
CREATE PROCEDURE fk.refresh_pools()
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE fk.pools;
    INSERT INTO fk.pools (locale, kind, sub, vals, extras, cum)
    SELECT locale, kind, sub,
           array_agg(value ORDER BY id), array_agg(extra ORDER BY id), array_agg(cp ORDER BY id)
    FROM (
        SELECT locale, kind, sub, id, value, extra,
               sum(weight) OVER (PARTITION BY locale, kind, sub ORDER BY id)
             / sum(weight) OVER (PARTITION BY locale, kind, sub) AS cp
        FROM (SELECT locale, kind, gender::text AS sub, id, value, ''::text AS extra, weight FROM fk.names
              UNION ALL
              SELECT locale, kind, sub, id + 10000000, value, extra, weight FROM fk.lexicon) src
    ) w
    GROUP BY locale, kind, sub;
END $$;

-- Loads one pool (one primary-key lookup).
CREATE FUNCTION fk.get_pool(p_locale text, p_kind text, p_sub text DEFAULT '')
RETURNS fk.pool LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE r fk.pool;
BEGIN
    SELECT vals, extras, cum INTO r FROM fk.pools
    WHERE locale = p_locale AND kind = p_kind AND sub = p_sub;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'no pool for locale=%, kind=%, sub=% (run CALL fk.refresh_pools())', p_locale, p_kind, p_sub;
    END IF;
    RETURN r;
END $$;

-- Weighted pick = inverse transform sampling: the index of the first element
-- whose cumulative probability is greater than u (binary search, O(log n)).
CREATE FUNCTION fk.pick_idx(p_cum double precision[], p_u double precision)
RETURNS integer LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE lo integer := 1; hi integer := array_length(p_cum, 1); mid integer;
BEGIN
    WHILE lo < hi LOOP
        mid := (lo + hi) / 2;
        IF p_cum[mid] > p_u THEN hi := mid; ELSE lo := mid + 1; END IF;
    END LOOP;
    RETURN lo;
END $$;

-- Replaces {key} placeholders:  fk.render('{a} {b}', '{a,b}', '{x,y}') = 'x y'
CREATE FUNCTION fk.render(p_pattern text, p_keys text[], p_vals text[])
RETURNS text LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE r text := p_pattern;
BEGIN
    FOR i IN 1 .. coalesce(array_length(p_keys, 1), 0) LOOP
        IF position('{' || p_keys[i] || '}' IN r) > 0 THEN
            r := replace(r, '{' || p_keys[i] || '}', coalesce(p_vals[i], ''));
        END IF;
    END LOOP;
    RETURN r;
END $$;

-- Fills a digit mask: '#' -> digit 0-9, 'N' -> digit 2-9, other characters kept.
--   fk.fill_pattern('+49 N## ####', prefix, 'phone')
CREATE FUNCTION fk.fill_pattern(p_pattern text, p_prefix text, p_salt text)
RETURNS text LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    v_n      integer := length(translate(p_pattern, '#N', '')) ;
    v_digits text;
    v_out    text    := '';
    v_pos    integer := 0;
    ch       text;
BEGIN
    v_n := length(p_pattern) - length(translate(p_pattern, '#N', ''));
    IF v_n = 0 THEN RETURN p_pattern; END IF;
    v_digits := fk.rand_digits(p_prefix, p_salt, v_n);
    FOR i IN 1 .. length(p_pattern) LOOP
        ch := substr(p_pattern, i, 1);
        IF ch = '#' THEN
            v_pos := v_pos + 1;  v_out := v_out || substr(v_digits, v_pos, 1);
        ELSIF ch = 'N' THEN
            v_pos := v_pos + 1;  v_out := v_out || (2 + substr(v_digits, v_pos, 1)::int % 8)::text;
        ELSE
            v_out := v_out || ch;
        END IF;
    END LOOP;
    RETURN v_out;
END $$;

-- Lower-case ASCII slug for e-mail local parts.  p_src/p_dst are the
-- locale specific replacements from fk.translit (de: ä->ae, ß->ss); remaining
-- accented letters are stripped to their base letter.
CREATE FUNCTION fk.slugify(p_text text, p_src text[], p_dst text[])
RETURNS text LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE s text := lower(p_text);
BEGIN
    FOR i IN 1 .. coalesce(array_length(p_src, 1), 0) LOOP
        s := replace(s, p_src[i], p_dst[i]);
    END LOOP;
    s := translate(s, 'àáâãäåāăąçćčďéèêëēėęěíìîïīłñńňóòôõöøōőřśšşťúùûüūůűýÿźżž',
                      'aaaaaaaaacccdeeeeeeeeiiiiilnnnooooooooorsssstuuuuuuuyyzzz');
    RETURN regexp_replace(s, '[^a-z0-9]', '', 'g');
END $$;
