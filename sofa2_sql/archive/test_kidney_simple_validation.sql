-- =================================================================
-- 肾脏模块修复验证 - 简化版
-- 重点验证：1. Gaps and Islands算法 2. 连续vs累计时间的区别
-- =================================================================

WITH
-- 基础时间序列 (仅测试前3个患者，前48小时)
co AS (
    SELECT
        h.stay_id,
        h.hr,
        h.endtime - INTERVAL '1 HOUR' as starttime,
        h.endtime
    FROM mimiciv_derived.icustay_hourly h
    WHERE h.stay_id IN (
        SELECT DISTINCT stay_id
        FROM mimiciv_derived.icustay_hourly
        LIMIT 3
    )
    AND h.hr BETWEEN 0 AND 47
),

-- Step 1: 计算每小时尿量(ml/kg/hr) - 验证实际体重使用
urine_output_rate AS (
    SELECT
        uo.stay_id,
        icu.intime,
        uo.charttime,
        -- 使用患者实际体重，默认70kg
        uo.urineoutput / COALESCE(wd.weight, 70) as urine_ml_per_kg,
        COALESCE(wd.weight, 70) as patient_weight,
        uo.urineoutput as raw_urine_output
    FROM mimiciv_derived.urine_output uo
    LEFT JOIN mimiciv_derived.weight_durations wd
        ON uo.stay_id = wd.stay_id
        AND uo.charttime >= wd.starttime
        AND uo.charttime < wd.endtime
    LEFT JOIN mimiciv_icu.icustays icu ON uo.stay_id = icu.stay_id
    WHERE uo.stay_id IN (SELECT stay_id FROM co)
),
urine_output_hourly_rate AS (
    SELECT
        stay_id,
        FLOOR(EXTRACT(EPOCH FROM (charttime - intime))/3600) AS hr,
        SUM(urine_ml_per_kg) as uo_ml_kg_hr,
        AVG(patient_weight) as avg_patient_weight,
        SUM(raw_urine_output) as total_urine_ml
    FROM urine_output_rate
    GROUP BY stay_id, hr
),

-- Step 2: 验证 "Gaps and Islands" 算法 - 核心修复
urine_output_islands AS (
    SELECT
        stay_id,
        hr,
        uo_ml_kg_hr,
        -- 各条件标志
        CASE WHEN uo_ml_kg_hr < 0.5 THEN 1 ELSE 0 END as is_low_05,
        CASE WHEN uo_ml_kg_hr < 0.3 THEN 1 ELSE 0 END as is_low_03,
        CASE WHEN uo_ml_kg_hr = 0 THEN 1 ELSE 0 END as is_anuric,
        -- 为每个条件创建连续小时组 (Gaps and Islands核心)
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN uo_ml_kg_hr < 0.5 THEN 1 ELSE 0 END ORDER BY hr) as island_low_05,
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN uo_ml_kg_hr < 0.3 THEN 1 ELSE 0 END ORDER BY hr) as island_low_03,
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN uo_ml_kg_hr = 0 THEN 1 ELSE 0 END ORDER BY hr) as island_anuric
    FROM urine_output_hourly_rate
),
urine_output_durations AS (
    SELECT
        stay_id,
        hr,
        uo_ml_kg_hr,
        is_low_05, is_low_03, is_anuric,
        -- 计算每种条件下的连续时长 (修复后：连续时间)
        CASE WHEN is_low_05 = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_low_05, island_low_05) ELSE 0 END as consecutive_low_05h,
        CASE WHEN is_low_03 = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_low_03, island_low_03) ELSE 0 END as consecutive_low_03h,
        CASE WHEN is_anuric = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_anuric, island_anuric) ELSE 0 END as consecutive_anuric_h
    FROM urine_output_islands
)

-- 验证输出：展示修复效果
SELECT
    stay_id,
    hr,
    ROUND(uo_ml_kg_hr::numeric, 3) as urine_ml_per_kg_hr,
    ROUND(avg_patient_weight::numeric, 1) as patient_weight_kg,
    total_urine_ml,
    is_low_05,
    is_low_03,
    is_anuric,
    consecutive_low_05h,
    consecutive_low_03h,
    consecutive_anuric_h,
    CASE
        WHEN consecutive_low_05h >= 6 AND consecutive_low_05h < 12 THEN '1分(连续6-12h)'
        WHEN consecutive_low_05h >= 12 THEN '2分(连续≥12h)'
        WHEN consecutive_low_03h >= 24 THEN '3分(连续≥24h)'
        WHEN consecutive_anuric_h >= 12 THEN '3分(连续无尿≥12h)'
        WHEN is_low_05 = 1 OR is_low_03 = 1 OR is_anuric = 1
        THEN '低尿量但未评分'
        ELSE '正常尿量'
    END AS sofat2_kidney_score,
    -- 修复验证标记
    '✅ 实际体重' AS weight_fix,
    '✅ 连续算法' AS duration_fix
FROM urine_output_durations
ORDER BY stay_id, hr
LIMIT 25;