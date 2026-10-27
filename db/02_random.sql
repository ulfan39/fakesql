-- =====================================================================
--  02_random.sql : deterministic random number generation
--
--  There is NO global generator state.  A "random" number is a pure
--  function of a text key:
--        key = locale | seed | batch | index-in-batch | salt
--  so the same arguments always give the same number, a user at position
--  (batch, idx) never depends on other users, and generation can run set-
--  based (no loops, can be parallel).
-- =====================================================================

-- Key prefix shared by all numbers of one user (computed once per user).
CREATE FUNCTION fk.key_prefix(p_locale text, p_seed bigint, p_batch integer, p_idx integer)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_locale || '|' || p_seed || '|' || p_batch || '|' || p_idx || '|'
$$;

-- Core primitive: uniform double in [0, 1).
-- md5(prefix || salt) is a stable 128-bit hash; its first 52 bits are
-- exactly representable in a double, so  bits / 2^52  is uniform in [0,1).
CREATE FUNCTION fk.u(p_prefix text, p_salt text)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (('x' || substr(md5(p_prefix || p_salt), 1, 13))::bit(52)::bigint)::double precision
           / 4503599627370496.0
$$;

-- Uniform double in [p_lo, p_hi).
CREATE FUNCTION fk.rand_uniform(p_prefix text, p_salt text, p_lo double precision, p_hi double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_lo + (p_hi - p_lo) * fk.u(p_prefix, p_salt)
$$;

-- Uniform integer in [p_lo, p_hi]  (both ends included).
CREATE FUNCTION fk.rand_int(p_prefix text, p_salt text, p_lo integer, p_hi integer)
RETURNS integer LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_lo + floor(fk.u(p_prefix, p_salt) * (p_hi - p_lo + 1))::integer
$$;

-- Normal (Gaussian) variate N(mean, sd^2) by the Box-Muller transform:
--   z = sqrt(-2 ln u1) * cos(2 pi u2)    with u1, u2 independent uniforms.
-- u1 is taken as 1 - u so that ln() never sees 0.
CREATE FUNCTION fk.rand_normal(p_prefix text, p_salt text, p_mean double precision, p_sd double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT p_mean + p_sd * sqrt(-2.0 * ln(1.0 - fk.u(p_prefix, p_salt || '#n1')))
                         * cos(2.0 * pi() * fk.u(p_prefix, p_salt || '#n2'))
$$;

-- Point uniformly distributed on the surface of the sphere.
--   longitude  = 360 u - 180                (uniform in [-180,180))
--   latitude   = asin(2 v - 1)  (in degrees)
-- Archimedes' hat-box theorem: the height z = sin(lat) of a uniform point
-- on the sphere is uniform on [-1,1]; taking asin() of a uniform value
-- therefore gives the right (cosine-shaped) latitude density.
CREATE FUNCTION fk.rand_sphere(p_prefix text, p_salt text,
                               OUT latitude double precision, OUT longitude double precision)
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT degrees(asin(2.0 * fk.u(p_prefix, p_salt || '#lat') - 1.0)),
           360.0 * fk.u(p_prefix, p_salt || '#lon') - 180.0
$$;

-- p_n random decimal digits as text.
-- One md5 gives a uniform 52-bit integer; its lowest 13 decimal digits are
-- uniform up to a bias < 0.1 % (2^52 is not a power of ten).  Longer strings
-- chain several hashes (salt || '#d' || block number).
CREATE FUNCTION fk.rand_digits(p_prefix text, p_salt text, p_n integer)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN p_n <= 0 THEN ''
                WHEN p_n <= 13 THEN
                     substr(lpad((('x' || substr(md5(p_prefix || p_salt || '#d0'), 1, 13))::bit(52)::bigint
                                  % 10000000000000)::text, 13, '0'), 1, p_n)
                ELSE fk.rand_digits(p_prefix, p_salt, 13)
                     || fk.rand_digits(p_prefix, p_salt || '+', p_n - 13)
           END
$$;
