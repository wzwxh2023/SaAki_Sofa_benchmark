-- =================================================================
-- SOFA-2 谵妄药物检测最终验证
-- 基于5种确认的核心抗精神病药物
-- =================================================================

-- 验证5种核心药物在数据库中的存在情况
SELECT
    'Haloperidol' as medication_class,
    COUNT(DISTINCT stay_id) as patient_count,
    COUNT(*) as prescription_count,
    MIN(starttime) as earliest_use,
    MAX(starttime) as latest_use
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE LOWER(pr.drug) LIKE '%haloperidol%'

UNION ALL

SELECT
    'Quetiapine' as medication_class,
    COUNT(DISTINCT stay_id) as patient_count,
    COUNT(*) as prescription_count,
    MIN(starttime) as earliest_use,
    MAX(starttime) as latest_use
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE LOWER(pr.drug) LIKE '%quetiapine%'

UNION ALL

SELECT
    'Olanzapine' as medication_class,
    COUNT(DISTINCT stay_id) as patient_count,
    COUNT(*) as prescription_count,
    MIN(starttime) as earliest_use,
    MAX(starttime) as latest_use
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE LOWER(pr.drug) LIKE '%olanzapine%'

UNION ALL

SELECT
    'Risperidone' as medication_class,
    COUNT(DISTINCT stay_id) as patient_count,
    COUNT(*) as prescription_count,
    MIN(starttime) as earliest_use,
    MAX(starttime) as latest_use
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE LOWER(pr.drug) LIKE '%risperidone%'

UNION ALL

SELECT
    'Ziprasidone' as medication_class,
    COUNT(DISTINCT stay_id) as patient_count,
    COUNT(*) as prescription_count,
    MIN(starttime) as earliest_use,
    MAX(starttime) as latest_use
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE LOWER(pr.drug) LIKE '%ziprasidone%'

ORDER BY patient_count DESC;

-- 验证谵妄药物检测的准确性
WITH delirium_meds_final AS (
    SELECT DISTINCT
        ie.stay_id,
        pr.starttime::date AS startdate,
        pr.stoptime::date AS stopdate,
        pr.drug,
        CASE
            WHEN LOWER(pr.drug) LIKE '%haloperidol%' THEN 'Haloperidol'
            WHEN LOWER(pr.drug) LIKE '%quetiapine%' THEN 'Quetiapine'
            WHEN LOWER(pr.drug) LIKE '%olanzapine%' THEN 'Olanzapine'
            WHEN LOWER(pr.drug) LIKE '%risperidone%' THEN 'Risperidone'
            WHEN LOWER(pr.drug) LIKE '%ziprasidone%' THEN 'Ziprasidone'
            ELSE 'Other'
        END AS medication_class,
        1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE (LOWER(pr.drug) LIKE '%haloperidol%'
           OR LOWER(pr.drug) LIKE '%quetiapine%'
           OR LOWER(pr.drug) LIKE '%olanzapine%'
           OR LOWER(pr.drug) LIKE '%risperidone%'
           OR LOWER(pr.drug) LIKE '%ziprasidone%')
)

-- 统计使用谵妄药物的患者特征
SELECT
    medication_class,
    COUNT(DISTINCT stay_id) as unique_patients,
    COUNT(*) as total_prescriptions,
    ROUND(AVG(prescriptions_per_patient), 2) as avg_prescriptions_per_patient
FROM (
    SELECT
        medication_class,
        stay_id,
        COUNT(*) as prescriptions_per_patient
    FROM delirium_meds_final
    GROUP BY medication_class, stay_id
) patient_stats
GROUP BY medication_class
ORDER BY unique_patients DESC;

-- 验证多药物使用情况
SELECT
    num_medications,
    COUNT(DISTINCT stay_id) as patient_count,
    ROUND(COUNT(DISTINCT stay_id) * 100.0 / (SELECT COUNT(DISTINCT stay_id) FROM delirium_meds_final), 2) as percentage
FROM (
    SELECT
        stay_id,
        COUNT(DISTINCT medication_class) as num_medications
    FROM delirium_meds_final
    GROUP BY stay_id
) multi_med_usage
GROUP BY num_medications
ORDER BY num_medications;

-- GCS评分与谵妄药物使用的关联验证
WITH delirium_meds_for_gcs AS (
    SELECT DISTINCT
        ie.stay_id,
        pr.starttime::date AS startdate,
        pr.stoptime::date AS stopdate,
        1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE (LOWER(pr.drug) LIKE '%haloperidol%'
           OR LOWER(pr.drug) LIKE '%quetiapine%'
           OR LOWER(pr.drug) LIKE '%olanzapine%'
           OR LOWER(pr.drug) LIKE '%risperidone%'
           OR LOWER(pr.drug) LIKE '%ziprasidone%')
),

gcs_distribution AS (
    SELECT
        co.stay_id,
        MIN(gcs.gcs) AS gcs_min,
        MAX(CASE
            WHEN dm.on_delirium_med = 1
                 AND (co.starttime)::date >= dm.startdate
                 AND (co.starttime)::date <= COALESCE(dm.stopdate, (co.starttime)::date + INTERVAL '1' DAY)
            THEN 1
            ELSE 0
        END) AS on_delirium_med
    FROM mimiciv_derived.icustay_hourly co
    LEFT JOIN mimiciv_derived.gcs gcs
        ON co.stay_id = gcs.stay_id
            AND (co.endtime - INTERVAL '1 HOUR') < gcs.charttime
            AND co.endtime >= gcs.charttime
    LEFT JOIN delirium_meds_for_gcs dm
        ON co.stay_id = dm.stay_id
    WHERE co.hr >= 0  -- ICU期间
    GROUP BY co.stay_id
),

sofa2_brain_scores AS (
    SELECT
        stay_id,
        gcs_min,
        on_delirium_med,
        CASE
            -- GCS 3-5 = 4
            WHEN gcs_min <= 5 THEN 4
            -- GCS 6-8 = 3
            WHEN gcs_min >= 6 AND gcs_min <= 8 THEN 3
            -- GCS 9-12 = 2
            WHEN gcs_min >= 9 AND gcs_min <= 12 THEN 2
            -- GCS 13-14 OR on delirium meds = 1
            WHEN (gcs_min >= 13 AND gcs_min <= 14) OR COALESCE(on_delirium_med, 0) = 1 THEN 1
            -- GCS 15 and no delirium meds = 0
            WHEN gcs_min = 15 AND COALESCE(on_delirium_med, 0) = 0 THEN 0
            ELSE NULL
        END AS brain_sofa2_score
    FROM gcs_distribution
    WHERE gcs_min IS NOT NULL
)

-- 最终验证：GCS评分分布与谵妄药物使用的关系
SELECT
    brain_sofa2_score,
    on_delirium_med,
    COUNT(DISTINCT stay_id) as patient_count,
    ROUND(AVG(gcs_min), 1) as avg_gcs,
    MIN(gcs_min) as min_gcs,
    MAX(gcs_min) as max_gcs
FROM sofa2_brain_scores
GROUP BY brain_sofa2_score, on_delirium_med
ORDER BY brain_sofa2_score, on_delirium_med;