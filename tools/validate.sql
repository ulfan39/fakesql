-- Statistical sanity checks of the generators (run with psql, ~15 s).
-- Expected: chi-square values below the 5 % critical values quoted in the comments.
CREATE TEMP TABLE v AS
SELECT g.* FROM generate_series(0, 4999) b, LATERAL fk.generate_users('en_US', 2024, b, 20) g;   -- 100 000 users

\echo '1) sphere: sin(latitude) must be uniform on [-1,1]  (10 bins, 9 dof, critical value 16.92)'
WITH b AS (SELECT width_bucket(sin(radians(latitude)), -1, 1.0000001, 10) k, count(*) c FROM v GROUP BY 1)
SELECT round(sum((c - 10000.0)^2 / 10000.0), 2) AS chi2_latitude FROM b;
\echo '   longitude uniform on [-180,180)  (12 bins, 11 dof, critical value 19.68)'
WITH b AS (SELECT width_bucket(longitude, -180, 180.0000001, 12) k, count(*) c FROM v GROUP BY 1)
SELECT round(sum((c - 100000.0/12)^2 / (100000.0/12)), 2) AS chi2_longitude FROM b;
\echo '   share of points with |latitude| > 60 deg (uniform sphere: 13.40 %, naive uniform lat/lon: 33.33 %)'
SELECT round(100.0 * count(*) FILTER (WHERE abs(latitude) > 60) / count(*), 2) AS pct FROM v;

\echo '2) normal distribution of height / weight (targets: M 175.3/7.6 and 89.7/15.0, F 161.5/7.1 and 77.0/15.0, corr 0.5)'
SELECT gender, round(avg(height_cm),1) h_mean, round(stddev(height_cm),2) h_sd,
       round(avg(weight_kg),1) w_mean, round(stddev(weight_kg),2) w_sd, round(corr(height_cm, weight_kg)::numeric,2) corr
FROM v GROUP BY gender ORDER BY gender;

\echo '3) discrete eye colour (targets 45 / 27 / 18 / 9 / 1 %)'
SELECT eye_color, round(100.0*count(*)/100000, 1) AS pct FROM v GROUP BY 1 ORDER BY 2 DESC;

\echo '4) reproducibility: the same batch twice gives the same fingerprint, another seed differs'
SELECT (SELECT md5(string_agg(x::text,'|')) FROM fk.generate_users('de_DE',42,3,10) x) =
       (SELECT md5(string_agg(x::text,'|')) FROM fk.generate_users('de_DE',42,3,10) x) AS same_args_same_data,
       (SELECT md5(string_agg(x::text,'|')) FROM fk.generate_users('de_DE',42,3,10) x) <>
       (SELECT md5(string_agg(x::text,'|')) FROM fk.generate_users('de_DE',43,3,10) x) AS other_seed_other_data,
       (SELECT fk.generate_user('de_DE',42,3,7)::text) =
       (SELECT x::text FROM fk.generate_users('de_DE',42,3,10) x OFFSET 7 LIMIT 1) AS single_user_equals_batch_row;
\echo '5) variety'
SELECT count(*) users, count(DISTINCT full_name) distinct_names, count(DISTINCT email) distinct_emails, count(DISTINCT address) distinct_addresses FROM v;
