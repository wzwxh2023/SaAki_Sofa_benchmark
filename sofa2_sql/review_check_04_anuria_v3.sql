-- Review Check #4 v3: <5mL vs =0mL 敏感性分析
WITH sepsis_stays AS (
    SELECT DISTINCT stay_id FROM (
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa1_delta
        UNION
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa2_delta
    ) t
),
anuria AS (
    SELECT
        u.stay_id, u.hr, u.uo_sum_12h,
        CASE WHEN u.uo_sum_12h < 5.0 THEN 1 ELSE 0 END AS flag_lt5,
        CASE WHEN u.uo_sum_12h = 0 THEN 1 ELSE 0 END AS flag_eq0,
        CASE WHEN u.uo_sum_12h > 0 AND u.uo_sum_12h < 5.0 THEN 1 ELSE 0 END AS flag_between
    FROM mimiciv_derived.sofa2_stage1_urine_fixed u
    INNER JOIN sepsis_stays ss ON u.stay_id = ss.stay_id
    WHERE u.hr BETWEEN 0 AND 23
      AND u.uo_sum_12h IS NOT NULL
)
SELECT
    (SELECT COUNT(DISTINCT stay_id) FROM sepsis_stays) AS total_sepsis_stays,
    COUNT(DISTINCT CASE WHEN flag_lt5 = 1 THEN stay_id END) AS stays_lt5ml,
    COUNT(DISTINCT CASE WHEN flag_eq0 = 1 THEN stay_id END) AS stays_eq0ml,
    COUNT(DISTINCT CASE WHEN flag_between = 1 THEN stay_id END) AS stays_between_0_and_5,
    SUM(flag_lt5) AS hours_lt5ml,
    SUM(flag_eq0) AS hours_eq0ml,
    SUM(flag_between) AS hours_between
FROM anuria;
