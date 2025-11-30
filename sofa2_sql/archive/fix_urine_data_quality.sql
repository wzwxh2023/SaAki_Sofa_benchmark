-- =================================================================
-- 修复SOFA2尿量数据质量问题
-- 问题：mimiciv_derived.urine_output表包含负值，导致评分异常
-- 解决方案：在计算前过滤负值和异常值
-- =================================================================

-- 1. 首先创建一个干净的尿量表
DROP TABLE IF EXISTS mimiciv_derived.urine_output_clean CASCADE;

CREATE TABLE mimiciv_derived.urine_output_clean AS
SELECT
    stay_id,
    charttime,
    -- 过滤负值和异常值：尿液输出应该是非负的合理值
    CASE
        WHEN urineoutput < 0 THEN 0  -- 将负值设为0
        WHEN urineoutput > 5000 THEN 5000  -- 限制单小时最大值（防止录入错误）
        ELSE urineoutput
    END as urineoutput
FROM mimiciv_derived.urine_output
WHERE urineoutput IS NOT NULL;

-- 创建索引
CREATE INDEX idx_urine_clean_stay ON mimiciv_derived.urine_output_clean(stay_id);
CREATE INDEX idx_urine_clean_time ON mimiciv_derived.urine_output_clean(charttime);

-- 2. 重新计算sofa2_stage1_urine表（使用清洁的尿量数据）
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_urine_fixed CASCADE;

-- 1. 准备体重（与原step2.sql相同）
WITH weight_avg_whole_stay AS (
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

-- 2. 准备网格数据（使用清洁的尿量数据）
uo_grid AS (
    SELECT
        ih.stay_id,
        ih.hr,
        ih.endtime,
        SUM(uo.urineoutput) AS uo_vol_hourly
    FROM mimiciv_derived.icustay_hourly ih
    LEFT JOIN mimiciv_derived.urine_output_clean uo  -- 使用清洁的尿量数据
           ON ih.stay_id = uo.stay_id
           AND uo.charttime > ih.endtime - INTERVAL '1 HOUR'
           AND uo.charttime <= ih.endtime
    WHERE ih.hr >= -24
    GROUP BY ih.stay_id, ih.hr, ih.endtime
)

-- 3. 计算滑动窗口
SELECT
    g.stay_id,
    g.hr,
    w.weight,

    SUM(uo_vol_hourly) OVER w6 AS uo_sum_6h,
    SUM(uo_vol_hourly) OVER w12 AS uo_sum_12h,
    SUM(uo_vol_hourly) OVER w24 AS uo_sum_24h,

    COUNT(*) OVER w6 AS cnt_6h,
    COUNT(*) OVER w12 AS cnt_12h,
    COUNT(*) OVER w24 AS cnt_24h

FROM uo_grid g
JOIN weight_final w ON g.stay_id = w.stay_id
WINDOW
    w6  AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 5 PRECEDING AND CURRENT ROW),
    w12 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 11 PRECEDING AND CURRENT ROW),
    w24 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW);

CREATE INDEX idx_st1_urine_fixed ON mimiciv_derived.sofa2_stage1_urine_fixed(stay_id, hr);

-- 3. 验证修复效果
SELECT
    'Before Fix' as data_status,
    'sofa2_stage1_urine' as table_name,
    COUNT(*) as total_records,
    COUNT(CASE WHEN uo_sum_24h < 0 THEN 1 END) as negative_count,
    ROUND(AVG(uo_sum_24h), 1) as avg_24h_urine,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY uo_sum_24h), 1) as median_24h_urine
FROM mimiciv_derived.sofa2_stage1_urine
WHERE hr BETWEEN 0 AND 23

UNION ALL

SELECT
    'After Fix' as data_status,
    'sofa2_stage1_urine_fixed' as table_name,
    COUNT(*) as total_records,
    COUNT(CASE WHEN uo_sum_24h < 0 THEN 1 END) as negative_count,
    ROUND(AVG(uo_sum_24h), 1) as avg_24h_urine,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY uo_sum_24h), 1) as median_24h_urine
FROM mimiciv_derived.sofa2_stage1_urine_fixed
WHERE hr BETWEEN 0 AND 23;

-- 4. 检查修复后的评分影响
WITH kidney_score_comparison AS (
    -- 修复前的评分
    SELECT
        stay_id,
        MAX(kidney_score) as kidney_score_before,
        COUNT(*) as record_count
    FROM mimiciv_derived.sofa2_hourly_raw
    WHERE hr BETWEEN 0 AND 23
    GROUP BY stay_id

    UNION ALL

    -- 模拟修复后的评分（需要重新运行step3）
    SELECT
        stay_id,
        NULL as kidney_score_after,  -- 待重新计算
        0 as record_count
    FROM mimiciv_derived.sofa2_stage1_urine_fixed
    WHERE hr BETWEEN 0 AND 23
)
SELECT
    'Score Distribution Impact' as analysis_type,
    kidney_score_before as kidney_score,
    COUNT(*) as patient_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM kidney_score_comparison
WHERE kidney_score_before IS NOT NULL
GROUP BY kidney_score_before
ORDER BY kidney_score_before;

-- 5. 提供修复建议
SELECT
    'Fix Recommendations' as analysis_type,
    'Use urine_output_clean in step3.sql' as recommendation_1,
    'Add data validation in step2.sql' as recommendation_2,
    'Re-run SOFA2 scoring pipeline' as recommendation_3,
    'Compare distributions before/after' as recommendation_4;

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.urine_output_clean IS 'Cleaned urine output data with negative and outlier values removed';
COMMENT ON TABLE mimiciv_derived.sofa2_stage1_urine_fixed IS 'Fixed SOFA2 stage 1 urine data using cleaned urine values';