-- =================================================================
-- SOFA-2肾脏评分数据缺失情况分析
-- =================================================================

-- 基本统计
SELECT
    '=== SOFA-2肾脏评分数据缺失分析 ===' as analysis_title;

-- 患者数据覆盖情况
SELECT
    '总患者数' as metric,
    COUNT(*) as count,
    '100.0%' as percentage
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    'ICU住院≥24小时患者',
    COUNT(CASE WHEN icu_los_hours >= 24 THEN 1 END),
    CAST(ROUND(COUNT(CASE WHEN icu_los_hours >= 24 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%'
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '完整24小时测量数据患者(≥24次测量)',
    COUNT(CASE WHEN total_measurements >= 24 THEN 1 END),
    CAST(ROUND(COUNT(CASE WHEN total_measurements >= 24 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%'
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '部分数据患者(1-23次测量)',
    COUNT(CASE WHEN total_measurements BETWEEN 1 AND 23 THEN 1 END),
    CAST(ROUND(COUNT(CASE WHEN total_measurements BETWEEN 1 AND 23 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%'
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '无测量数据患者',
    COUNT(CASE WHEN total_measurements = 0 THEN 1 END),
    CAST(ROUND(COUNT(CASE WHEN total_measurements = 0 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%'
FROM mimiciv_derived.first_day_sofa2;

-- 患者39553978具体情况分析
SELECT
    '=== 患者39553978详细分析 ===' as case_study;

SELECT
    stay_id,
    icu_los_hours,
    total_measurements,
    kidney,
    data_completeness,
    CASE
        WHEN total_measurements = 0 THEN '无尿量数据'
        WHEN total_measurements < 6 THEN '数据极少(<6小时)'
        WHEN total_measurements < 12 THEN '数据不足(6-11小时)'
        WHEN total_measurements < 24 THEN '数据不完整(12-23小时)'
        ELSE '数据完整(≥24小时)'
    END as data_assessment
FROM mimiciv_derived.first_day_sofa2
WHERE stay_id = 39553978;

-- 当前尿量数据访问检查
SELECT
    '=== 检查step3能否访问尿量数据 ===' as data_check;

-- 检查尿量预处理表的数据
SELECT
    'sofa2_stage1_urine表数据量' as table_check,
    COUNT(*) as total_records,
    COUNT(DISTINCT stay_id) as unique_stays
FROM mimiciv_derived.sofa2_stage1_urine

UNION ALL

SELECT
    '患者39553978尿量记录数',
    COUNT(*),
    1
FROM mimiciv_derived.sofa2_stage1_urine
WHERE stay_id = 39553978;

-- 检查该患者的具体尿量数据
SELECT
    '=== 患者39553978的尿量预处理数据 ===' as patient_urine_data;

SELECT
    stay_id,
    hr,
    patient_weight,
    cnt_6h,
    uo_sum_6h,
    CASE WHEN patient_weight > 0 THEN ROUND(uo_sum_6h / patient_weight / 6.0, 3) ELSE 0 END as urine_rate_6h,
    cnt_12h,
    uo_sum_12h,
    cnt_24h,
    uo_sum_24h
FROM mimiciv_derived.sofa2_stage1_urine
WHERE stay_id = 39553978
ORDER BY hr;