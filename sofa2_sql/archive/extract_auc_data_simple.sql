-- =================================================================
-- 简化版AUC数据提取脚本
-- 使用COPY命令直接导出CSV
-- =================================================================

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
        f2.icu_outtime
    FROM mimiciv_derived.first_day_sofa f1
    INNER JOIN mimiciv_derived.first_day_sofa2 f2 ON f1.stay_id = f2.stay_id
    INNER JOIN (
        SELECT stay_id, ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY icu_intime DESC) as rn
        FROM mimiciv_derived.first_day_sofa2
    ) ranked ON f2.stay_id = ranked.stay_id
    WHERE ranked.rn = 1
)

-- 基础统计
SELECT '=== 基础统计 ===' as analysis_section
UNION ALL
SELECT '总患者数: ' || CAST(COUNT(*) AS VARCHAR) as analysis_section
FROM last_icu_stays
UNION ALL
SELECT 'ICU死亡数: ' || CAST(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) AS VARCHAR) as analysis_section
FROM last_icu_stays
UNION ALL
SELECT 'SOFA-1平均分: ' || CAST(ROUND(AVG(sofa_score), 2) AS VARCHAR) as analysis_section
FROM last_icu_stays
UNION ALL
SELECT 'SOFA-2平均分: ' || CAST(ROUND(AVG(sofa2_score), 2) AS VARCHAR) as analysis_section
FROM last_icu_stays
UNION ALL
SELECT '' as analysis_section
UNION ALL
SELECT '=== 重症患者分析 ===' as analysis_section
UNION ALL
SELECT 'SOFA-1重症(≥8): ' || CAST(COUNT(CASE WHEN sofa_score >= 8 THEN 1 END) AS VARCHAR) ||
       '例, 死亡率: ' || CAST(ROUND(COUNT(CASE WHEN sofa_score >= 8 AND icu_mortality = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(CASE WHEN sofa_score >= 8 THEN 1 END), 0), 2) AS VARCHAR) || '%' as analysis_section
FROM last_icu_stays
UNION ALL
SELECT 'SOFA-2重症(≥8): ' || CAST(COUNT(CASE WHEN sofa2_score >= 8 THEN 1 END) AS VARCHAR) ||
       '例, 死亡率: ' || CAST(ROUND(COUNT(CASE WHEN sofa2_score >= 8 AND icu_mortality = 1 THEN 1 END) * 100.0 / NULLIF(COUNT(CASE WHEN sofa2_score >= 8 THEN 1 END), 0), 2) AS VARCHAR) || '%' as analysis_section
FROM last_icu_stays;

-- 数据提取完成提示
SELECT '=== 数据提取完成 ===' as completion_status
UNION ALL
SELECT '请在服务器上运行以下命令导出完整数据:' as instruction
UNION ALL
SELECT 'COPY (SELECT * FROM ('
UNION ALL
SELECT 'SELECT stay_id, subject_id, hadm_id, sofa_score, sofa2_score, icu_mortality, hospital_expire_flag, age, gender, icu_los_hours, icu_los_days, severity_category, failing_organs_count, icu_intime, icu_outtime FROM (' as instruction
UNION ALL
SELECT '    SELECT stay_id, subject_id, hadm_id, sofa_score, sofa2_score, icu_mortality, hospital_expire_flag, age, gender, icu_los_hours, icu_los_days, severity_category, failing_organs_count, icu_intime, icu_outtime FROM mimiciv_derived.first_day_sofa f1' as instruction
UNION ALL
SELECT '        INNER JOIN mimiciv_derived.first_day_sofa2 f2 ON f1.stay_id = f2.stay_id' as instruction
UNION ALL
SELECT '        INNER JOIN (SELECT stay_id, ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY icu_intime DESC) as rn FROM mimiciv_derived.first_day_sofa2) ranked ON f2.stay_id = ranked.stay_id' as instruction
UNION ALL
SELECT '        WHERE ranked.rn = 1' as instruction
UNION ALL
SELECT ') data) TO \'/tmp/survival_auc_data.csv\' WITH CSV HEADER;' as final_command;