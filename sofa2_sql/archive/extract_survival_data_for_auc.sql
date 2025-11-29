-- =================================================================
-- SOFA vs SOFA2 ICU生存预测AUC分析 - 数据提取脚本
-- 功能：提取最后一次住院的数据，用于计算AUC
-- 输出：CSV格式的数据，可导入Python/R进行精确AUC计算
-- =================================================================

-- 创建最后一次住院队列
WITH last_icu_stays AS (
    SELECT
        f1.stay_id,
        f1.subject_id,
        f1.hadm_id,
        f1.sofa AS sofa_score,
        f2.sofa2 AS sofa2_score,
        f2.icu_mortality,
        f2.hospital_expire_flag,
        f2.age,
        f2.gender,
        f2.icu_los_hours,
        f2.icu_los_days,
        f2.severity_category,
        f2.failing_organs_count,
        f2.icu_intime,
        f2.icu_outtime,
        ROW_NUMBER() OVER (PARTITION BY f1.subject_id ORDER BY f2.icu_intime DESC) as rn
    FROM mimiciv_derived.first_day_sofa f1
    INNER JOIN mimiciv_derived.first_day_sofa2 f2 ON f1.stay_id = f2.stay_id
),
final_cohort AS (
    SELECT
        stay_id,
        subject_id,
        hadm_id,
        sofa_score,
        sofa2_score,
        icu_mortality,
        hospital_expire_flag,
        age,
        gender,
        icu_los_hours,
        icu_los_days,
        severity_category,
        failing_organs_count,
        icu_intime,
        icu_outtime
    FROM last_icu_stays
    WHERE rn = 1
)

-- 基础统计报告
SELECT '=== 基础队列统计 ===' as report_section
UNION ALL
SELECT '总患者数: ' || CAST(COUNT(*) AS VARCHAR) as report_section
FROM final_cohort
UNION ALL
SELECT 'ICU死亡数: ' || CAST(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) AS VARCHAR) as report_section
FROM final_cohort
UNION ALL
SELECT 'ICU死亡率: ' || CAST(ROUND(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%' as report_section
FROM final_cohort
UNION ALL
SELECT '医院死亡数: ' || CAST(COUNT(CASE WHEN hospital_expire_flag = 1 THEN 1 END) AS VARCHAR) as report_section
FROM final_cohort
UNION ALL
SELECT '医院死亡率: ' || CAST(ROUND(COUNT(CASE WHEN hospital_expire_flag = 1 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%' as report_section
FROM final_cohort
UNION ALL
SELECT '' as report_section
UNION ALL
SELECT '=== 评分分布统计 ===' as report_section
UNION ALL
SELECT 'SOFA平均分: ' || CAST(ROUND(AVG(sofa_score), 2) AS VARCHAR) as report_section
FROM final_cohort
UNION ALL
SELECT 'SOFA-2平均分: ' || CAST(ROUND(AVG(sofa2_score), 2) AS VARCHAR) as report_section
FROM final_cohort
UNION ALL
SELECT 'SOFA标准差: ' || CAST(ROUND(STDDEV(sofa_score), 2) AS VARCHAR) as report_section
FROM final_cohort
UNION ALL
SELECT 'SOFA-2标准差: ' || CAST(ROUND(STDDEV(sofa2_score), 2) AS VARCHAR) as report_section
FROM final_cohort
UNION ALL
SELECT '' as report_section
UNION ALL
SELECT '=== 分层死亡率分析 ===' as report_section
UNION ALL
SELECT 'SOFA重症(≥8分): ' || CAST(COUNT(CASE WHEN sofa_score >= 8 THEN 1 END) AS VARCHAR) ||
       '例, 死亡率: ' || CAST(ROUND(COUNT(CASE WHEN sofa_score >= 8 AND icu_mortality = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(CASE WHEN sofa_score >= 8 THEN 1 END), 0), 2) AS VARCHAR) || '%' as report_section
FROM final_cohort
UNION ALL
SELECT 'SOFA-2重症(≥8分): ' || CAST(COUNT(CASE WHEN sofa2_score >= 8 THEN 1 END) AS VARCHAR) ||
       '例, 死亡率: ' || CAST(ROUND(COUNT(CASE WHEN sofa2_score >= 8 AND icu_mortality = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(CASE WHEN sofa2_score >= 8 THEN 1 END), 0), 2) AS VARCHAR) || '%' as report_section
FROM final_cohort;

-- 输出数据用于外部AUC计算
SELECT '=== 用于AUC计算的数据 (可复制到CSV文件) ===' as export_note
UNION ALL
SELECT 'subject_id,sofa_score,sofa2_score,icu_mortality,hospital_expire_flag,age,gender,icu_los_hours' as header
UNION ALL
SELECT
    CAST(subject_id AS VARCHAR) || ',' ||
    CAST(sofa_score AS VARCHAR) || ',' ||
    CAST(sofa2_score AS VARCHAR) || ',' ||
    CAST(icu_mortality AS VARCHAR) || ',' ||
    CAST(hospital_expire_flag AS VARCHAR) || ',' ||
    CAST(age AS VARCHAR) || ',' ||
    gender || ',' ||
    REPLACE(CAST(icu_los_hours AS VARCHAR), '.', ',') as csv_data
FROM final_cohort
ORDER BY subject_id;