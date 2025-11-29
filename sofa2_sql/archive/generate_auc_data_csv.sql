-- =================================================================
-- 生成AUC分析数据的CSV导出脚本
-- 功能：提取最后一次ICU住院的数据，格式化为CSV格式
-- 用途：可直接复制结果到CSV文件，导入Python/R进行精确AUC计算
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
        f2.icu_outtime,
        ROW_NUMBER() OVER (PARTITION BY f1.subject_id ORDER BY f2.icu_intime DESC, f1.stay_id DESC) as rn
    FROM mimiciv_derived.first_day_sofa f1
    INNER JOIN mimiciv_derived.first_day_sofa2 f2 ON f1.stay_id = f2.stay_id
)

SELECT
    'CSV数据复制提示：' as instruction,
    '1. 复制下方所有结果（除第一行外）' as step1,
    '2. 保存为csv文件（如：survival_auc_data.csv）' as step2,
    '3. 导入Python/R进行AUC计算' as step3
UNION ALL

SELECT
    'subject_id,stay_id,sofa_score,sofa2_score,icu_mortality,hospital_expire_flag,age,gender,icu_los_hours,icu_los_days,severity_category,failing_organs_count,icu_intime,icu_outtime' as csv_header
UNION ALL

SELECT
    CAST(subject_id AS VARCHAR) || ',' ||
    CAST(stay_id AS VARCHAR) || ',' ||
    CAST(sofa_score AS VARCHAR) || ',' ||
    CAST(sofa2_score AS VARCHAR) || ',' ||
    CAST(icu_mortality AS VARCHAR) || ',' ||
    CAST(hospital_expire_flag AS VARCHAR) || ',' ||
    CAST(age AS VARCHAR) || ',' ||
    '''' || gender || '''' || ',' ||  -- 用引号包围性别字段
    REPLACE(CAST(icu_los_hours AS VARCHAR), '.', ',') || ',' ||  -- 替换小数点
    REPLACE(CAST(icu_los_days AS VARCHAR), '.', ',') || ',' ||
    '''' || REPLACE(severity_category, ',', ';') || '''' || ',' ||  -- 替换逗号并加引号
    CAST(failing_organs_count AS VARCHAR) || ',' ||
    '''' || TO_CHAR(icu_intime, 'YYYY-MM-DD HH24:MI:SS') || '''' || ',' ||
    '''' || TO_CHAR(icu_outtime, 'YYYY-MM-DD HH24:MI:SS') || '''' as csv_row
FROM last_icu_stays
WHERE rn = 1
ORDER BY subject_id;