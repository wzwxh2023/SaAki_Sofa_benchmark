-- =================================================================
-- SOFA2肾脏评分时间窗口修复 - 最终版
-- 问题：滑动窗口在早期小时数据不足，导致尿量速率被错误计算
-- 解决：根据实际可用时间选择合适的评估窗口
-- =================================================================

-- 1. 创建修复后的尿量表
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_urine_fixed CASCADE;

CREATE TABLE mimiciv_derived.sofa2_stage1_urine_fixed AS
WITH
-- 1. 准备体重数据（复用原有逻辑）
weight_avg_whole_stay AS (
    SELECT stay_id, AVG(weight) as weight_full_avg
    FROM mimiciv_derived.weight_durations
    WHERE weight > 0
    GROUP BY stay_id
),
weight_from_ce AS (
    SELECT
        stay_id,
        AVG(
            CASE
                WHEN itemid = 226531 THEN valuenum * 0.453592  -- lbs → kg
                ELSE valuenum                                   -- 已经是kg
            END
        ) as weight_ce
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (224639, 226512, 226531)
      AND valuenum > 0
      AND (
          (itemid IN (224639, 226512) AND valuenum BETWEEN 20 AND 300)
          OR
          (itemid = 226531 AND valuenum BETWEEN 44 AND 660)
      )
    GROUP BY stay_id
),
weight_final AS (
    SELECT
        ie.stay_id,
        COALESCE(
            fd.weight_admit,                    -- 1. 入院体重
            fd.weight,                          -- 2. 首日均值
            ws.weight_full_avg,                 -- 3. 全程均值
            ce.weight_ce,                       -- 4. chartevents原始
            CASE WHEN p.gender = 'F' THEN 70.0  -- 5. 性别中位数（女）
                 ELSE 83.3                      -- 5. 性别中位数（男）
            END
        ) AS weight
    FROM mimiciv_icu.icustays ie
    JOIN mimiciv_hosp.patients p ON ie.subject_id = p.subject_id
    LEFT JOIN mimiciv_derived.first_day_weight fd ON ie.stay_id = fd.stay_id
    LEFT JOIN weight_avg_whole_stay ws ON ie.stay_id = ws.stay_id
    LEFT JOIN weight_from_ce ce ON ie.stay_id = ce.stay_id
),

-- 2. 准备原始尿量网格数据
uo_grid AS (
    SELECT
        ih.stay_id,
        ih.hr,
        ih.endtime,
        COALESCE(SUM(uo.urineoutput), 0) AS uo_vol_hourly
    FROM mimiciv_derived.icustay_hourly ih
    LEFT JOIN mimiciv_derived.urine_output uo
           ON ih.stay_id = uo.stay_id
           AND uo.charttime > ih.endtime - INTERVAL '1 HOUR'
           AND uo.charttime <= ih.endtime
    WHERE ih.hr >= -24
    GROUP BY ih.stay_id, ih.hr, ih.endtime
)

-- 3. 计算滑动窗口（保持原有计算方式）
SELECT
    g.stay_id,
    g.hr,
    w.weight,

    -- 滑动窗口累积值
    SUM(uo_vol_hourly) OVER w6 AS uo_sum_6h,
    SUM(uo_vol_hourly) OVER w12 AS uo_sum_12h,
    SUM(uo_vol_hourly) OVER w24 AS uo_sum_24h,

    COUNT(*) OVER w6 AS cnt_6h,
    COUNT(*) OVER w12 AS cnt_12h,
    COUNT(*) OVER w24 AS cnt_24h,

    -- **关键修复：根据实际可用时间计算尿量速率**
    CASE
        WHEN hr >= 0 AND w.weight > 0 THEN
            CASE
                WHEN hr >= 24 THEN uo_sum_24h / w.weight / 24  -- 有完整24小时数据
                WHEN hr >= 12 THEN uo_sum_12h / w.weight / 12  -- 有12小时数据
                WHEN hr >= 6 THEN uo_sum_6h / w.weight / 6    -- 有6小时数据
                ELSE NULL  -- 前6小时数据不足，不评估尿量速率
            END
        ELSE NULL
    END AS urine_rate_ml_kg_h,

    -- **标记数据是否足够进行评分**
    CASE
        WHEN hr >= 24 THEN 'full_24h'
        WHEN hr >= 12 THEN 'full_12h'
        WHEN hr >= 6 THEN 'full_6h'
        ELSE 'insufficient'
    END AS time_window_status

FROM uo_grid g
JOIN weight_final w ON g.stay_id = w.stay_id
WINDOW
    w6  AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 5 PRECEDING AND CURRENT ROW),
    w12 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 11 PRECEDING AND CURRENT ROW),
    w24 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW);

CREATE INDEX idx_st1_urine_fixed ON mimiciv_derived.sofa2_stage1_urine_fixed(stay_id, hr);

-- 4. 验证修复效果
SELECT
    'Fix Verification' as analysis_type,
    hr as hour_after_admission,
    time_window_status,
    COUNT(*) as total_patients,
    ROUND(AVG(urine_rate_ml_kg_h)::numeric, 3) as avg_corrected_rate_ml_kg_h,
    COUNT(CASE WHEN urine_rate_ml_kg_h < 0.3 THEN 1 END) as corrected_score_3_count,
    ROUND(COUNT(CASE WHEN urine_rate_ml_kg_h < 0.3 THEN 1 END) * 100.0 / COUNT(*), 2) as corrected_score_3_percentage
FROM mimiciv_derived.sofa2_stage1_urine_fixed
WHERE hr BETWEEN 0 AND 23
AND weight > 0
AND time_window_status != 'insufficient'
GROUP BY hr, time_window_status
ORDER BY hr;

-- 5. 比较修复前后的差异
WITH comparison_data AS (
    -- 修复前的数据
    SELECT
        hr,
        (uo_sum_24h / weight / cnt_24h) as original_rate,
        CASE WHEN (uo_sum_24h / weight / cnt_24h) < 0.3 THEN 1 ELSE 0 END as original_score_3
    FROM mimiciv_derived.sofa2_stage1_urine
    WHERE hr BETWEEN 0 AND 23 AND weight > 0 AND cnt_24h > 0

    UNION ALL

    -- 修复后的数据
    SELECT
        hr,
        urine_rate_ml_kg_h as corrected_rate,
        CASE WHEN urine_rate_ml_kg_h < 0.3 AND time_window_status != 'insufficient' THEN 1 ELSE 0 END as corrected_score_3
    FROM mimiciv_derived.sofa2_stage1_urine_fixed
    WHERE hr BETWEEN 0 AND 23 AND weight > 0 AND time_window_status != 'insufficient'
)
SELECT
    'Before vs After Comparison' as analysis_type,
    calculation_method,
    hr as hour_after_admission,
    ROUND(AVG(rate)::numeric, 3) as avg_urine_rate_ml_kg_h,
    COUNT(*) as total_records,
    COUNT(CASE WHEN score_3 = 1 THEN 1 END) as score_3_count,
    ROUND(COUNT(CASE WHEN score_3 = 1 THEN 1 END) * 100.0 / COUNT(*), 2) as score_3_percentage
FROM (
    SELECT 'Original (Problematic)' as calculation_method, hr, original_rate as rate, original_score_3
    FROM comparison_data WHERE original_rate IS NOT NULL

    UNION ALL

    SELECT 'Corrected' as calculation_method, hr, corrected_rate as rate, corrected_score_3
    FROM comparison_data WHERE corrected_rate IS NOT NULL
) rates
GROUP BY calculation_method, hr
ORDER BY calculation_method, hr;

-- 6. 核心修复：step3.sql中需要更新的肾脏评分逻辑
/*
将step3.sql中的kidney_sofa部分替换为以下内容：

kidney_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        kl.creatinine,
        kl.potassium,
        kl.ph,
        kl.bicarbonate,
        rr.on_rrt,
        u.weight,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,
        u.urine_rate_ml_kg_h,        -- 使用修复后的尿量速率
        u.time_window_status,        -- 新增：时间窗口状态

        -- **修复后的肾脏评分逻辑**
        CASE
            -- Score 4: RRT或Virtual RRT（需要足够数据进行评估）
            WHEN rr.on_rrt = 1 THEN 4
            WHEN (kl.creatinine > 1.2 OR u.urine_rate_ml_kg_h < 0.3)
                 AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
                 AND u.time_window_status IN ('full_24h', 'full_12h', 'full_6h') THEN 4

            -- Score 3: 严重肾功能不全
            WHEN kl.creatinine > 3.5 THEN 3
            WHEN u.urine_rate_ml_kg_h < 0.3 AND u.time_window_status IN ('full_24h', 'full_12h') THEN 3
            WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3

            -- Score 2: 中度肾功能不全
            WHEN kl.creatinine > 2.0 THEN 2
            WHEN u.urine_rate_ml_kg_h < 0.5 AND u.time_window_status IN ('full_12h', 'full_6h') THEN 2

            -- Score 1: 轻度肾功能不全
            WHEN kl.creatinine > 1.2 THEN 1
            WHEN u.urine_rate_ml_kg_h < 0.5 AND u.time_window_status = 'full_6h' THEN 1

            ELSE 0
        END AS kidney_score

    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON co.stay_id = kl.stay_id AND co.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON co.stay_id = rr.stay_id AND co.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine_fixed u ON co.stay_id = u.stay_id AND co.hr = u.hr  -- 使用修复后的尿量表
)
*/

-- 7. 预期修复效果验证
SELECT
    'Expected Fix Impact' as analysis_type,
    'Traditional SOFA' as scoring_system,
    renal as kidney_score,
    COUNT(*) as patient_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM mimiciv_derived.first_day_sofa
WHERE renal IS NOT NULL
GROUP BY renal

UNION ALL

SELECT
    'Expected Fix Impact' as analysis_type,
    'SOFA2 (Before Fix)' as scoring_system,
    kidney as kidney_score,
    COUNT(*) as patient_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM mimiciv_derived.first_day_sofa2
WHERE kidney IS NOT NULL
GROUP BY kidney

UNION ALL

SELECT
    'Expected Fix Impact' as analysis_type,
    'SOFA2 (After Fix - Expected)' as scoring_system,
    kidney_score,
    NULL as patient_count,  -- 需要实际运行修复脚本后获得
    'Should match Traditional SOFA (~8-10% with score 3)' as percentage
FROM (VALUES (0), (1), (2), (3), (4)) scores(kidney_score)
ORDER BY scoring_system, kidney_score;

-- 8. 实施建议
SELECT
    'Implementation Steps' as step_number,
    'Fix Implementation' as category,
    instruction as action_required
FROM (
    VALUES
        ('1', 'Modify step2.sql', 'Create sofa2_stage1_urine_fixed table with time window validation'),
        ('2', 'Modify step3.sql', 'Update kidney_sofa section to use urine_rate_ml_kg_h and time_window_status'),
        ('3', 'Re-run pipeline', 'Execute step2.sql and step3.sql in sequence'),
        ('4', 'Validate results', 'Compare first_day_sofa2_fixed with first_day_sofa distributions'),
        ('5', 'Quality check', 'Ensure kidney score 3 percentage drops from ~75% to ~8-10%')
) steps(step_number, category, instruction);

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.sofa2_stage1_urine_fixed IS 'SOFA2 urine data with time window validation - only evaluates urine rates when sufficient data is available';
COMMENT ON COLUMN mimiciv_derived.sofa2_stage1_urine_fixed.urine_rate_ml_kg_h IS 'Corrected urine rate calculated using appropriate time window (6h/12h/24h based on available data)';
COMMENT ON COLUMN mimiciv_derived.sofa2_stage1_urine_fixed.time_window_status IS 'Indicates whether sufficient data exists for urine output evaluation';