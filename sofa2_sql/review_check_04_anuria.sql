-- Review Check #4: Anuria 定义敏感性分析
-- 比较 <5mL/12h (当前) vs 0mL/12h (严格原文) 的差异

WITH sepsis_stays AS (
    SELECT DISTINCT stay_id FROM (
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa1_delta
        UNION
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa2_delta
    ) t
),
co AS (
    SELECT ih.stay_id, ih.hr
    FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
    INNER JOIN sepsis_stays ss ON ih.stay_id = ss.stay_id
    WHERE ih.hr BETWEEN 0 AND 23
),
anuria_check AS (
    SELECT
        co.stay_id,
        co.hr,
        u.uo_sum_12h,
        u.cnt_12h,
        -- 当前标准: <5 mL
        CASE WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 1 ELSE 0 END AS anuria_5ml,
        -- 严格标准: = 0 mL
        CASE WHEN u.uo_sum_12h = 0 AND u.cnt_12h >= 12 THEN 1 ELSE 0 END AS anuria_0ml,
        -- 介于 0-5 mL 之间
        CASE WHEN u.uo_sum_12h > 0 AND u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 1 ELSE 0 END AS anuria_between
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON co.stay_id = u.stay_id AND co.hr = u.hr
)

-- Part A: 小时级别
SELECT
    'Part A: 小时级别' AS label,
    SUM(anuria_5ml) AS hours_lt5ml,
    SUM(anuria_0ml) AS hours_eq0ml,
    SUM(anuria_between) AS hours_between_0_and_5,
    COUNT(DISTINCT CASE WHEN anuria_5ml = 1 THEN stay_id END) AS stays_lt5ml,
    COUNT(DISTINCT CASE WHEN anuria_0ml = 1 THEN stay_id END) AS stays_eq0ml,
    COUNT(DISTINCT CASE WHEN anuria_between = 1 THEN stay_id END) AS stays_only_between
FROM anuria_check;
