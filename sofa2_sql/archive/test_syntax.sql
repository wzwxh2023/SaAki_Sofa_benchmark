-- 测试语法检查：仅包含前几个CTE
WITH co AS (
    SELECT stay_id, hr
    FROM (VALUES (1, 0)) AS t(stay_id, hr)
),
drug_params AS (
    SELECT
        ARRAY['%propofol%', '%midazolam%'] AS sedation_patterns,
        ARRAY['%haloperidol%', '%quetiapine%'] AS delirium_patterns
),
gcs_stg AS (
    SELECT
        1 AS stay_id,
        NOW() AS charttime,
        15 AS gcs,
        0 AS is_sedated
),
delirium_hourly AS (
    SELECT
        1 AS stay_id,
        0 AS hr,
        0 AS on_delirium_med
),
gcs AS (
    SELECT
        1 AS stay_id,
        0 AS hr,
        0 AS brain
    FROM co
    LEFT JOIN LATERAL (
        SELECT 15 AS gcs, 0 AS is_sedated
    ) AS gcs_vals ON TRUE
    LEFT JOIN delirium_hourly d ON co.stay_id = d.stay_id AND co.hr = d.hr
)
SELECT * FROM gcs LIMIT 5;
