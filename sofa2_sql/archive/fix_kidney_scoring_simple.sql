-- =================================================================
-- 简化版SOFA2肾脏评分修复方案
-- 核心问题：尿量速率计算应该使用固定小时数而不是动态count
-- =================================================================

-- 1. 首先验证问题：检查当前尿量计算的异常
WITH urine_calculation_check AS (
    SELECT
        s.stay_id,
        s.hr,
        kl.creatinine,
        u.weight,
        u.cnt_24h,
        u.uo_sum_24h,

        -- 当前错误的计算方式（除以动态count）
        CASE WHEN u.cnt_24h > 0 AND u.weight > 0
             THEN u.uo_sum_24h / u.weight / u.cnt_24h
             ELSE NULL END as urine_rate_wrong,

        -- 修复后的计算方式（除以固定24小时）
        CASE WHEN u.weight > 0
             THEN u.uo_sum_24h / u.weight / 24
             ELSE NULL END as urine_rate_fixed

    FROM mimiciv_derived.sofa2_hourly_raw s
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON s.stay_id = kl.stay_id AND s.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON s.stay_id = u.stay_id AND s.hr = u.hr
    WHERE s.hr BETWEEN 0 AND 23  -- ICU入院后24小时
    AND kl.creatinine IS NOT NULL
)
SELECT
    'Urine Rate Comparison' as analysis_type,
    ROUND(AVG(urine_rate_wrong), 3) as avg_wrong_calculation,
    ROUND(AVG(urine_rate_fixed), 3) as avg_fixed_calculation,
    ROUND(AVG(urine_rate_wrong) / NULLIF(AVG(urine_rate_fixed), 0), 2) as overestimation_factor
FROM urine_calculation_check
WHERE urine_rate_wrong IS NOT NULL
  AND urine_rate_fixed IS NOT NULL;

-- 2. 重新计算正确的SOFA2肾脏评分
WITH kidney_score_fixed AS (
    SELECT
        stay_id,
        hr,
        kl.creatinine,
        kl.potassium,
        kl.ph,
        kl.bicarbonate,
        rr.on_rrt,
        u.weight,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,

        -- 修复后的尿量速率（使用固定小时数）
        CASE WHEN u.weight > 0 THEN u.uo_sum_6h / u.weight / 6 ELSE NULL END as urine_rate_6h_fixed,
        CASE WHEN u.weight > 0 THEN u.uo_sum_12h / u.weight / 12 ELSE NULL END as urine_rate_12h_fixed,
        CASE WHEN u.weight > 0 THEN u.uo_sum_24h / u.weight / 24 ELSE NULL END as urine_rate_24h_fixed,

        -- 原始错误的肾脏评分
        s.kidney_score as kidney_score_original,

        -- 修复后的SOFA2肾脏评分
        CASE
            -- Score 4
            WHEN rr.on_rrt = 1 THEN 4
            WHEN (kl.creatinine > 1.2 OR (u.weight > 0 AND u.uo_sum_24h / u.weight / 24 < 0.3))
                 AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12)) THEN 4

            -- Score 3
            WHEN kl.creatinine > 3.5 THEN 3
            WHEN u.weight > 0 AND u.uo_sum_24h / u.weight / 24 < 0.3 THEN 3
            WHEN u.uo_sum_12h < 5.0 AND u.uo_sum_12h > 0 THEN 3  -- 12小时内无尿

            -- Score 2
            WHEN kl.creatinine > 2.0 THEN 2
            WHEN u.weight > 0 AND u.uo_sum_12h / u.weight / 12 < 0.5 THEN 2

            -- Score 1
            WHEN kl.creatinine > 1.2 THEN 1
            WHEN u.weight > 0 AND u.uo_sum_6h / u.weight / 6 < 0.5 THEN 1

            ELSE 0
        END AS kidney_score_fixed

    FROM mimiciv_derived.sofa2_hourly_raw s
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON s.stay_id = kl.stay_id AND s.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON s.stay_id = rr.stay_id AND s.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON s.stay_id = u.stay_id AND s.hr = u.hr
    WHERE s.hr BETWEEN 0 AND 23
)

-- 3. 比较修复前后的评分分布
SELECT
    'Original SOFA2' as scoring_system,
    kidney_score_original as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM kidney_score_fixed
WHERE kidney_score_original IS NOT NULL
GROUP BY kidney_score_original

UNION ALL

SELECT
    'Fixed SOFA2' as scoring_system,
    kidney_score_fixed as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM kidney_score_fixed
WHERE kidney_score_fixed IS NOT NULL
GROUP BY kidney_score_fixed

UNION ALL

SELECT
    'Traditional SOFA (Reference)' as scoring_system,
    renal as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM mimiciv_derived.first_day_sofa
WHERE renal IS NOT NULL
GROUP BY renal
ORDER BY scoring_system, kidney_score;

-- 4. 评分变化统计
WITH score_changes AS (
    SELECT
        stay_id,
        MAX(kidney_score_original) as max_original_score,
        MAX(kidney_score_fixed) as max_fixed_score,
        MAX(kidney_score_original) - MAX(kidney_score_fixed) as score_change
    FROM kidney_score_fixed
    GROUP BY stay_id
)
SELECT
    score_change as original_minus_fixed,
    COUNT(*) as patient_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM score_changes
GROUP BY score_change
ORDER BY score_change;

-- 5. 具体案例分析：查看评分差异最大的患者
WITH case_studies AS (
    SELECT
        ks.stay_id,
        ks.hr,
        ks.creatinine,
        ks.potassium,
        ks.ph,
        ks.bicarbonate,
        ks.on_rrt,
        ks.weight,
        ks.uo_sum_24h,
        ks.urine_rate_wrong,
        ks.urine_rate_fixed,
        ks.kidney_score_original,
        ks.kidney_score_fixed,

        -- 传统SOFA评分作为参考
        fs.renal as traditional_renal

    FROM (
        SELECT
            stay_id, hr, creatinine, potassium, ph, bicarbonate, on_rrt, weight,
            uo_sum_24h,
            CASE WHEN u.cnt_24h > 0 AND u.weight > 0
                 THEN u.uo_sum_24h / u.weight / u.cnt_24h
                 ELSE NULL END as urine_rate_wrong,
            CASE WHEN u.weight > 0
                 THEN u.o_sum_24h / u.weight / 24
                 ELSE NULL END as urine_rate_fixed,
            kidney_score_original, kidney_score_fixed
        FROM kidney_score_fixed
    ) ks
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON ks.stay_id = fs.stay_id
    WHERE ks.kidney_score_original != ks.kidney_score_fixed
    ORDER BY ABS(ks.kidney_score_original - ks.kidney_score_fixed) DESC
    LIMIT 20
)
SELECT * FROM case_studies;

-- 6. 关键指标统计
WITH final_summary AS (
    SELECT
        -- 原始SOFA2统计
        AVG(kidney_score_original) as avg_sofa2_original,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kidney_score_original) as median_sofa2_original,

        -- 修复后SOFA2统计
        AVG(kidney_score_fixed) as avg_sofa2_fixed,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kidney_score_fixed) as median_sofa2_fixed,

        -- 传统SOFA统计（参考）
        (SELECT AVG(renal) FROM mimiciv_derived.first_day_sofa WHERE renal IS NOT NULL) as avg_traditional,
        (SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY renal) FROM mimiciv_derived.first_day_sofa WHERE renal IS NOT NULL) as median_traditional
    FROM kidney_score_fixed
)
SELECT
    'Summary Statistics' as analysis_type,
    ROUND(avg_sofa2_original, 2) as original_avg,
    ROUND(avg_sofa2_fixed, 2) as fixed_avg,
    ROUND(avg_traditional, 2) as traditional_avg,
    ROUND(median_sofa2_original, 2) as original_median,
    ROUND(median_sofa2_fixed, 2) as fixed_median,
    ROUND(median_traditional, 2) as traditional_median
FROM final_summary;