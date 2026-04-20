-- Review Check #4 v2: Anuria 敏感性分析
-- 使用 sofa2_stage1_urine_fixed 表

WITH sepsis_stays AS (
    SELECT DISTINCT stay_id FROM (
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa1_delta
        UNION
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa2_delta
    ) t
),

-- Part A: 先看 cnt_12h 的分布, 确定合理阈值
stats AS (
    SELECT
        u.cnt_12h,
        u.uo_sum_12h
    FROM mimiciv_derived.sofa2_stage1_urine_fixed u
    INNER JOIN sepsis_stays ss ON u.stay_id = ss.stay_id
    WHERE u.hr BETWEEN 0 AND 23
)
SELECT
    'Part A: 数据概况' AS label,
    COUNT(*) AS total_hours,
    SUM(CASE WHEN cnt_12h >= 12 THEN 1 ELSE 0 END) AS cnt_ge12,
    SUM(CASE WHEN cnt_12h >= 6 THEN 1 ELSE 0 END) AS cnt_ge6,
    SUM(CASE WHEN cnt_12h >= 1 THEN 1 ELSE 0 END) AS cnt_ge1,
    SUM(CASE WHEN uo_sum_12h IS NOT NULL AND uo_sum_12h < 5.0 THEN 1 ELSE 0 END) AS uo_lt5_any,
    SUM(CASE WHEN uo_sum_12h IS NOT NULL AND uo_sum_12h = 0 THEN 1 ELSE 0 END) AS uo_eq0_any
FROM stats;
