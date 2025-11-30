-- =================================================================
-- 修复SOFA2肾脏评分计算逻辑
-- 问题：尿量速率计算错误，应该使用固定的小时数而不是动态count
-- =================================================================

-- 修复后的肾脏评分逻辑
WITH kidney_scoring_fixed AS (
    SELECT
        stay_id,
        hr,
        creatinine,
        potassium,
        ph,
        bicarbonate,
        on_rrt,
        weight,

        -- 固定时间窗口的尿量计算
        uo_sum_6h,
        uo_sum_12h,
        uo_sum_24h,

        -- 修复后的尿量速率（使用固定小时数而不是动态count）
        CASE WHEN weight > 0 THEN uo_sum_6h / weight / 6 ELSE NULL END as urine_rate_6h,
        CASE WHEN weight > 0 THEN uo_sum_12h / weight / 12 ELSE NULL END as urine_rate_12h,
        CASE WHEN weight > 0 THEN uo_sum_24h / weight / 24 ELSE NULL END as urine_rate_24h,

        -- 修复后的SOFA2肾脏评分
        CASE
            -- Score 4: RRT或Virtual RRT
            WHEN on_rrt = 1 THEN 4
            WHEN (creatinine > 1.2 OR urine_rate_24h < 0.3)
                 AND (potassium >= 6.0 OR (ph <= 7.2 AND bicarbonate <= 12)) THEN 4

            -- Score 3: 严重肾功能不全
            WHEN creatinine > 3.5 THEN 3
            WHEN urine_rate_24h < 0.3 THEN 3
            WHEN uo_sum_12h < 5.0 AND uo_sum_12h > 0 THEN 3  -- 12小时内无尿

            -- Score 2: 中度肾功能不全
            WHEN creatinine > 2.0 THEN 2
            WHEN urine_rate_12h < 0.5 THEN 2

            -- Score 1: 轻度肾功能不全
            WHEN creatinine > 1.2 THEN 1
            WHEN urine_rate_6h < 0.5 THEN 1

            ELSE 0
        END AS kidney_score_fixed

    FROM mimiciv_derived.sofa2_stage1_kidney_labs kl
    JOIN mimiciv_derived.sofa2_stage1_rrt rr ON kl.stay_id = rr.stay_id AND kl.hr = rr.hr
    JOIN mimiciv_derived.sofa2_stage1_urine u ON kl.stay_id = u.stay_id AND kl.hr = u.hr
    WHERE kl.hr BETWEEN 0 AND 23  -- ICU入院后24小时
)

-- 1. 比较修复前后的评分分布
SELECT
    'Before Fix' as scoring_status,
    kidney_score as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM (
    SELECT DISTINCT stay_id,
           (SELECT MAX(kidney_score)
            FROM mimiciv_derived.sofa2_hourly_raw
            WHERE stay_id = s.stay_id AND hr BETWEEN 0 AND 23) as kidney_score
    FROM mimiciv_derived.sofa2_hourly_raw s
    WHERE hr BETWEEN 0 AND 23
) t
WHERE kidney_score IS NOT NULL
GROUP BY kidney_score

UNION ALL

SELECT
    'After Fix' as scoring_status,
    kidney_score_fixed as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM (
    SELECT DISTINCT stay_id,
           MAX(kidney_score_fixed) as kidney_score_fixed
    FROM kidney_scoring_fixed
    GROUP BY stay_id
) t
WHERE kidney_score_fixed IS NOT NULL
GROUP BY kidney_score_fixed
ORDER BY scoring_status, kidney_score;

-- 2. 详细对比每个患者的评分变化
WITH comparison AS (
    SELECT
        ks.stay_id,
        -- 原始SOFA2评分
        (SELECT MAX(kidney_score)
         FROM mimiciv_derived.sofa2_hourly_raw
         WHERE stay_id = ks.stay_id AND hr BETWEEN 0 AND 23) as sofa2_original,

        -- 修复后SOFA2评分
        MAX(ks.kidney_score_fixed) as sofa2_fixed,

        -- 传统SOFA评分（作为参考）
        fs.renal as sofa_traditional,

        -- 关键指标
        MAX(ks.creatinine) as max_creatinine,
        MAX(CASE WHEN ks.weight > 0 THEN ks.uo_sum_24h / ks.weight / 24 ELSE NULL END) as urine_rate_24h_fixed,
        MAX(ks.on_rrt) as on_rrt

    FROM kidney_scoring_fixed ks
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON ks.stay_id = fs.stay_id
    WHERE ks.hr BETWEEN 0 AND 23
    GROUP BY ks.stay_id, fs.renal
)
SELECT
    score_difference,
    COUNT(*) as patient_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM (
    SELECT
        stay_id,
        sofa2_original,
        sofa2_fixed,
        sofa_traditional,
        sofa2_original - sofa2_fixed as score_difference
    FROM comparison
) t
GROUP BY score_difference
ORDER BY score_difference;

-- 3. 创建修复后的first_day_sofa2表
-- 删除已存在的表
DROP TABLE IF EXISTS mimiciv_derived.first_day_sofa2_fixed CASCADE;

-- 创建修复后的表
CREATE TABLE mimiciv_derived.first_day_sofa2_fixed AS
SELECT
    stay_id,
    subject_id,
    hadm_id,

    -- 取0-23小时内各系统的最高分（修复后）
    MAX(brain_score) AS brain,
    MAX(respiratory_score) AS respiratory,
    MAX(cardiovascular_score) AS cardiovascular,
    MAX(liver_score) AS liver,

    -- 使用修复后的肾脏评分
    MAX(ks.kidney_score_fixed) AS kidney,
    MAX(hemostasis_score) AS hemostasis,

    -- 修复后的总分
    MAX(brain_score + respiratory_score + cardiovascular_score + liver_score +
        ks.kidney_score_fixed + hemostasis_score) AS sofa2_total_fixed

FROM mimiciv_derived.sofa2_hourly_raw hr
JOIN kidney_scoring_fixed ks ON hr.stay_id = ks.stay_id AND hr.hr = ks.hr
WHERE hr.hr BETWEEN 0 AND 23  -- ICU入院后24小时（0-23小时）
GROUP BY stay_id, subject_id, hadm_id;

-- 创建索引
CREATE INDEX idx_first_day_sofa2_fixed_stay ON mimiciv_derived.first_day_sofa2_fixed(stay_id);
CREATE INDEX idx_first_day_sofa2_fixed_subject ON mimiciv_derived.first_day_sofa2_fixed(subject_id);
CREATE INDEX idx_first_day_sofa2_fixed_hadm ON mimiciv_derived.first_day_sofa2_fixed(hadm_id);
CREATE INDEX idx_first_day_sofa2_fixed_total ON mimiciv_derived.first_day_sofa2_fixed(sofa2_total_fixed);

-- 4. 最终对比：修复后SOFA2 vs 传统SOFA
SELECT
    'Traditional SOFA' as scoring_system,
    renal as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM mimiciv_derived.first_day_sofa
WHERE renal IS NOT NULL
GROUP BY renal

UNION ALL

SELECT
    'SOFA2 Fixed' as scoring_system,
    kidney as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM mimiciv_derived.first_day_sofa2_fixed
WHERE kidney IS NOT NULL
GROUP BY kidney
ORDER BY scoring_system, kidney_score;

-- 5. 验证修复效果
WITH validation_stats AS (
    SELECT
        fs.renal as sofa_traditional,
        fs2_fixed.kidney as sofa2_fixed,
        ABS(fs.renal - fs2_fixed.kidney) as absolute_difference,
        fs.sofa as sofa_total_traditional,
        fs2_fixed.sofa2_total_fixed as sofa2_total_fixed

    FROM mimiciv_derived.first_day_sofa fs
    JOIN mimiciv_derived.first_day_sofa2_fixed fs2_fixed ON fs.stay_id = fs2_fixed.stay_id
)
SELECT
    'Score Difference Distribution' as metric_type,
    absolute_difference,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM validation_stats
GROUP BY absolute_difference
ORDER BY absolute_difference;

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.first_day_sofa2_fixed IS 'First day SOFA2 scores (0-23 hours after ICU admission) - Kidney scoring fixed';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2_fixed.kidney IS 'Maximum kidney SOFA2 score in first 24 hours (fixed calculation)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2_fixed.sofa2_total_fixed IS 'Maximum total SOFA2 score in first 24 hours (fixed)';