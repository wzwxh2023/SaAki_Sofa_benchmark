-- =================================================================
-- SOFA-1 vs SOFA-2 分析数据提取脚本
-- 提取所有相关数据供后续R/Python分析使用
-- =================================================================

-- 1. 主要数据集：SOFA评分与预后数据
-- 包含两个评分系统的完整评分、器官系统评分、死亡率等
DROP TABLE IF EXISTS sofa_comparison_main_dataset;
CREATE TEMP TABLE sofa_comparison_main_dataset AS
SELECT
    -- 基础标识符
    fds2.stay_id,
    fds2.subject_id,
    fds2.hadm_id,

    -- 时间信息
    fds2.icu_intime,
    fds2.icu_outtime,
    fds2.window_start_time as sofa2_window_start,
    fds2.window_end_time as sofa2_window_end,
    fds2.first_measurement_time,
    fds2.last_measurement_time,

    -- SOFA-1评分（来自官方sepsis3表）
    s3.sofa_score as sofa1_score,
    s3.respiration as sofa1_respiration,
    s3.coagulation as sofa1_coagulation,
    s3.liver as sofa1_liver,
    s3.cardiovascular as sofa1_cardiovascular,
    s3.cns as sofa1_cns,
    s3.renal as sofa1_renal,
    s3.antibiotic_time,
    s3.culture_time,
    s3.suspected_infection_time,
    s3.sofa_time as sofa1_time,

    -- SOFA-2评分
    fds2.sofa2 as sofa2_score,
    fds2.respiratory as sofa2_respiratory,
    fds2.cardiovascular as sofa2_cardiovascular,
    fds2.liver as sofa2_liver,
    fds2.kidney as sofa2_kidney,
    fds2.brain as sofa2_brain,
    fds2.hemostasis as sofa2_hemostasis,
    fds2.sofa2_icu_admission as sofa2_icu_admission_score,

    -- 预后信息
    fds2.icu_mortality,
    fds2.hospital_expire_flag,
    fds2.icu_los_hours,
    fds2.icu_los_days,

    -- 患者基本信息
    fds2.age,
    fds2.gender,
    fds2.race,
    fds2.admission_type,
    fds2.admission_location,
    fds2.severity_category,
    fds2.organ_failure_flag,
    fds2.failing_organs_count,
    fds2.data_completeness,
    fds2.trend_first_day,

    -- 脓毒症状态
    s3.sepsis3 as sofa1_sepsis,
    CASE WHEN fds2.sofa2 >= 2 AND EXISTS (
        SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
        WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
        LIMIT 1
    ) THEN true ELSE false END as sofa2_sepsis,

    -- 感染状态
    CASE WHEN EXISTS (
        SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
        WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
        LIMIT 1
    ) THEN true ELSE false END as has_suspected_infection

FROM mimiciv_derived.first_day_sofa2 fds2
LEFT JOIN mimiciv_derived.sepsis3 s3 ON fds2.stay_id = s3.stay_id;

-- 2. 输出主数据集
COPY (
    SELECT * FROM sofa_comparison_main_dataset
    ORDER BY stay_id
) TO '/tmp/sofa_comparison_main_dataset.csv' WITH CSV HEADER;

-- 3. SOFA-1脓毒症患者详细信息
COPY (
    SELECT
        stay_id,
        subject_id,
        hadm_id,
        sofa_score as sofa1_total,
        respiration as sofa1_resp,
        coagulation as sofa1_coag,
        liver as sofa1_liver,
        cardiovascular as sofa1_cv,
        cns as sofa1_cns,
        renal as sofa1_renal,
        icu_mortality,
        hospital_expire_flag,
        icu_los_hours,
        age,
        gender,
        race,
        admission_type,
        severity_category,
        organ_failure_flag,
        failing_organs_count,
        antibiotic_time,
        culture_time,
        suspected_infection_time,
        sofa_time
    FROM mimiciv_derived.sepsis3
    WHERE sepsis3 = true
    ORDER BY stay_id
) TO '/tmp/sofa1_sepsis_patients.csv' WITH CSV HEADER;

-- 4. SOFA-2脓毒症患者详细信息
COPY (
    SELECT DISTINCT
        fds2.stay_id,
        fds2.subject_id,
        fds2.hadm_id,
        fds2.sofa2 as sofa2_total,
        fds2.respiratory as sofa2_resp,
        fds2.cardiovascular as sofa2_cv,
        fds2.liver as sofa2_liver,
        fds2.kidney as sofa2_kidney,
        fds2.brain as sofa2_brain,
        fds2.hemostasis as sofa2_hemostasis,
        fds2.icu_mortality,
        fds2.hospital_expire_flag,
        fds2.icu_los_hours,
        fds2.age,
        fds2.gender,
        fds2.race,
        fds2.admission_type,
        fds2.severity_category,
        fds2.organ_failure_flag,
        fds2.failing_organs_count,
        fds2.window_start_time,
        fds2.window_end_time,
        fds2.icu_intime,
        fds2.icu_outtime
    FROM mimiciv_derived.first_day_sofa2 fds2
    JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
    WHERE fds2.sofa2 >= 2
        AND soi.suspected_infection = 1
        AND fds2.stay_id IS NOT NULL
    ORDER BY fds2.stay_id
) TO '/tmp/sofa2_sepsis_patients.csv' WITH CSV HEADER;

-- 5. 可疑感染时间数据
COPY (
    SELECT DISTINCT
        soi.stay_id,
        soi.suspected_infection_time,
        soi.suspected_infection,
        soi.specimen,
        soi.org_or_item,
        soi.antibiotic_time,
        soi.culture_time
    FROM mimiciv_derived.suspicion_of_infection soi
    WHERE soi.stay_id IN (
        SELECT stay_id FROM sofa_comparison_main_dataset
    )
    ORDER BY soi.stay_id, soi.suspected_infection_time
) TO '/tmp/suspicion_of_infection_data.csv' WITH CSV HEADER;

-- 6. ICU住院基本信息
COPY (
    SELECT
        icu.stay_id,
        icu.subject_id,
        icu.hadm_id,
        icu.icu_intime,
        icu.icu_outtime,
        icu.los_icu_days,
        icu.first_careunit,
        icu.last_careunit,
        icu.admission_type,
        icu.icu_los_hours,
        icu.icu_los_days,
        CASE WHEN icu.expire_flag = 1 THEN true ELSE false END as icu_expire_flag
    FROM mimiciv_icu.icustays icu
    WHERE icu.stay_id IN (
        SELECT stay_id FROM sofa_comparison_main_dataset
    )
    ORDER BY icu.stay_id
) TO '/tmp/icu_stays_basic_info.csv' WITH CSV HEADER;

-- 7. 患者基本信息
COPY (
    SELECT DISTINCT
        fds2.stay_id,
        fds2.subject_id,
        fds2.age,
        fds2.gender,
        fds2.race,
        fds2.admission_type,
        fds2.admission_location,
        fds2.hospital_expire_flag
    FROM mimiciv_derived.first_day_sofa2 fds2
    WHERE fds2.stay_id IN (
        SELECT stay_id FROM sofa_comparison_main_dataset
    )
    ORDER BY fds2.stay_id
) TO '/tmp/patient_demographics.csv' WITH CSV HEADER;

-- 8. 评分分布统计
COPY (
    SELECT 'SOFA1_Total' as score_type, sofa1_score as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa1_score IS NOT NULL
    GROUP BY sofa1_score

    UNION ALL

    SELECT 'SOFA2_Total' as score_type, sofa2_score as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa2_score IS NOT NULL
    GROUP BY sofa2_score

    UNION ALL

    SELECT 'SOFA1_Resp' as score_type, sofa1_respiration as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa1_respiration IS NOT NULL
    GROUP BY sofa1_respiration

    UNION ALL

    SELECT 'SOFA2_Resp' as score_type, sofa2_respiratory as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa2_respiratory IS NOT NULL
    GROUP BY sofa2_respiratory

    UNION ALL

    SELECT 'SOFA1_CV' as score_type, sofa1_cardiovascular as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa1_cardiovascular IS NOT NULL
    GROUP BY sofa1_cardiovascular

    UNION ALL

    SELECT 'SOFA2_CV' as score_type, sofa2_cardiovascular as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa2_cardiovascular IS NOT NULL
    GROUP BY sofa2_cardiovascular

    UNION ALL

    SELECT 'SOFA1_Liver' as score_type, sofa1_liver as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa1_liver IS NOT NULL
    GROUP BY sofa1_liver

    UNION ALL

    SELECT 'SOFA2_Liver' as score_type, sofa2_liver as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa2_liver IS NOT NULL
    GROUP BY sofa2_liver

    UNION ALL

    SELECT 'SOFA1_Renal' as score_type, sofa1_renal as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa1_renal IS NOT NULL
    GROUP BY sofa1_renal

    UNION ALL

    SELECT 'SOFA2_Renal' as score_type, sofa2_kidney as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa2_kidney IS NOT NULL
    GROUP BY sofa2_kidney

    UNION ALL

    SELECT 'SOFA1_CNS' as score_type, sofa1_cns as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa1_cns IS NOT NULL
    GROUP BY sofa1_cns

    UNION ALL

    SELECT 'SOFA2_Brain' as score_type, sofa2_brain as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa2_brain IS NOT NULL
    GROUP BY sofa2_brain

    UNION ALL

    SELECT 'SOFA1_Coag' as score_type, sofa1_coagulation as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa1_coagulation IS NOT NULL
    GROUP BY sofa1_coagulation

    UNION ALL

    SELECT 'SOFA2_Hemostasis' as score_type, sofa2_hemostasis as score_value, COUNT(*) as frequency
    FROM sofa_comparison_main_dataset
    WHERE sofa2_hemostasis IS NOT NULL
    GROUP BY sofa2_hemostasis

    ORDER BY score_type, score_value
) TO '/tmp/sofa_score_distributions.csv' WITH CSV HEADER;

-- 9. 数据质量报告
COPY (
    SELECT
        'Total_Patients' as metric,
        COUNT(DISTINCT stay_id) as value,
        'Unique ICU stays in dataset' as description
    FROM sofa_comparison_main_dataset

    UNION ALL

    SELECT
        'SOFA1_Complete' as metric,
        COUNT(DISTINCT stay_id) as value,
        'Patients with complete SOFA-1 scores' as description
    FROM sofa_comparison_main_dataset
    WHERE sofa1_score IS NOT NULL

    UNION ALL

    SELECT
        'SOFA2_Complete' as metric,
        COUNT(DISTINCT stay_id) as value,
        'Patients with complete SOFA-2 scores' as description
    FROM sofa_comparison_main_dataset
    WHERE sofa2_score IS NOT NULL

    UNION ALL

    SELECT
        'Both_Complete' as metric,
        COUNT(DISTINCT stay_id) as value,
        'Patients with both SOFA-1 and SOFA-2 scores' as description
    FROM sofa_comparison_main_dataset
    WHERE sofa1_score IS NOT NULL AND sofa2_score IS NOT NULL

    UNION ALL

    SELECT
        'SOFA1_Sepsis' as metric,
        COUNT(DISTINCT stay_id) as value,
        'SOFA-1 defined sepsis patients' as description
    FROM sofa_comparison_main_dataset
    WHERE sofa1_sepsis = true

    UNION ALL

    SELECT
        'SOFA2_Sepsis' as metric,
        COUNT(DISTINCT stay_id) as value,
        'SOFA-2 defined sepsis patients' as description
    FROM sofa_comparison_main_dataset
    WHERE sofa2_sepsis = true

    UNION ALL

    SELECT
        'Both_Sepsis' as metric,
        COUNT(DISTINCT stay_id) as value,
        'Patients defined as sepsis by both methods' as description
    FROM sofa_comparison_main_dataset
    WHERE sofa1_sepsis = true AND sofa2_sepsis = true

    UNION ALL

    SELECT
        'ICU_Deaths' as metric,
        COUNT(DISTINCT stay_id) as value,
        'ICU mortality cases' as description
    FROM sofa_comparison_main_dataset
    WHERE icu_mortality = 1

    UNION ALL

    SELECT
        'Hospital_Deaths' as metric,
        COUNT(DISTINCT stay_id) as value,
        'Hospital mortality cases' as description
    FROM sofa_comparison_main_dataset
    WHERE hospital_expire_flag = 1

    ORDER BY metric
) TO '/tmp/data_quality_report.csv' WITH CSV HEADER;

-- 输出数据集摘要
SELECT '=== 数据提取完成 ===' as status
UNION ALL
SELECT '主数据集记录数: ' || COUNT(*)::text FROM sofa_comparison_main_dataset
UNION ALL
SELECT 'SOFA-1脓毒症患者: ' || COUNT(DISTINCT stay_id)::text FROM sofa_comparison_main_dataset WHERE sofa1_sepsis = true
UNION ALL
SELECT 'SOFA-2脓毒症患者: ' || COUNT(DISTINCT stay_id)::text FROM sofa_comparison_main_dataset WHERE sofa2_sepsis = true
UNION ALL
SELECT 'ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 2)::text || '%' FROM sofa_comparison_main_dataset
UNION ALL
SELECT '平均ICU住院时长: ' || ROUND(AVG(icu_los_hours), 1)::text || ' 小时' FROM sofa_comparison_main_dataset WHERE icu_los_hours IS NOT NULL;