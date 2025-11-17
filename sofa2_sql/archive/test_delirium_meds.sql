-- =================================================================
-- 测试谵妄药物检测功能
-- =================================================================

-- 查询数据库中核心谵妄治疗药物
-- 基于5种确认的核心抗精神病药物
SELECT DISTINCT LOWER(drug) AS drug_name
FROM mimiciv_hosp.prescriptions
WHERE LOWER(drug) LIKE '%haloperidol%'
   OR LOWER(drug) LIKE '%quetiapine%'
   OR LOWER(drug) LIKE '%olanzapine%'
   OR LOWER(drug) LIKE '%risperidone%'
   OR LOWER(drug) LIKE '%ziprasidone%'
ORDER BY 1;

-- 测试谵妄药物检测CTE逻辑
WITH delirium_meds_test AS (
    SELECT DISTINCT
        ie.stay_id,
        pr.starttime::date AS startdate,
        pr.stoptime::date AS stopdate,
        pr.drug,
        1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr
        ON ie.hadm_id = pr.hadm_id
    WHERE (LOWER(pr.drug) LIKE '%haloperidol%'
           OR LOWER(pr.drug) LIKE '%quetiapine%'
           OR LOWER(pr.drug) LIKE '%olanzapine%'
           OR LOWER(pr.drug) LIKE '%risperidone%'
           OR LOWER(pr.drug) LIKE '%ziprasidone%')
)

-- 统计各种谵妄药物的使用情况
SELECT
    drug,
    COUNT(DISTINCT stay_id) AS unique_patients,
    COUNT(*) AS total_prescriptions,
    MIN(starttime) AS first_use,
    MAX(starttime) AS last_use
FROM delirium_meds_test
GROUP BY drug
ORDER BY unique_patients DESC;

-- 检查是否有患者使用多种谵妄药物
SELECT
    stay_id,
    STRING_AGG(DISTINCT drug, ', ') AS delirium_meds_used,
    COUNT(DISTINCT drug) AS num_delirium_meds
FROM delirium_meds_test
GROUP BY stay_id
HAVING COUNT(DISTINCT drug) > 1
ORDER BY num_delirium_meds DESC, stay_id
LIMIT 10;

-- 验证GCS评分逻辑
WITH delirium_meds AS (
    SELECT DISTINCT
        ie.stay_id,
        pr.starttime::date AS startdate,
        pr.stoptime::date AS stopdate,
        1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr
        ON ie.hadm_id = pr.hadm_id
    WHERE (LOWER(pr.drug) LIKE '%haloperidol%'
           OR LOWER(pr.drug) LIKE '%quetiapine%'
           OR LOWER(pr.drug) LIKE '%olanzapine%'
           OR LOWER(pr.drug) LIKE '%risperidone%'
           OR LOWER(pr.drug) LIKE '%ziprasidone%')
),

gcs_test AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(gcs.gcs) AS gcs_min
    FROM mimiciv_derived.icustay_hourly co
    LEFT JOIN mimiciv_derived.gcs gcs
        ON co.stay_id = gcs.stay_id
            AND (co.endtime - INTERVAL '1 HOUR') < gcs.charttime
            AND co.endtime >= gcs.charttime
    GROUP BY co.stay_id, co.hr
),

brain_delirium_test AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN dm.on_delirium_med = 1
                 AND (co.starttime)::date >= dm.startdate
                 AND (co.starttime)::date <= COALESCE(dm.stopdate, (co.starttime)::date + INTERVAL '1' DAY)
            THEN 1
            ELSE 0
        END) AS on_delirium_med
    FROM mimiciv_derived.icustay_hourly co
    LEFT JOIN delirium_meds dm
        ON co.stay_id = dm.stay_id
    GROUP BY co.stay_id, co.hr
)

-- 测试SOFA-2脑部评分逻辑
SELECT
    gt.stay_id,
    gt.hr,
    gt.gcs_min,
    bdt.on_delirium_med,
    CASE
        -- GCS 3-5 or severe motor response impairment = 4
        WHEN gt.gcs_min <= 5 THEN 4
        -- GCS 6-8 = 3
        WHEN gt.gcs_min >= 6 AND gt.gcs_min <= 8 THEN 3
        -- GCS 9-12 = 2
        WHEN gt.gcs_min >= 9 AND gt.gcs_min <= 12 THEN 2
        -- GCS 13-14 OR on delirium meds = 1
        WHEN (gt.gcs_min >= 13 AND gt.gcs_min <= 14) OR COALESCE(bdt.on_delirium_med, 0) = 1 THEN 1
        -- GCS 15 and no delirium meds = 0
        WHEN gt.gcs_min = 15 AND COALESCE(bdt.on_delirium_med, 0) = 0 THEN 0
        -- Missing data = null
        WHEN gt.gcs_min IS NULL AND COALESCE(bdt.on_delirium_med, 0) = 0 THEN NULL
        ELSE 0
    END AS brain_sofa2_score
FROM gcs_test gt
LEFT JOIN brain_delirium_test bdt
    ON gt.stay_id = bdt.stay_id AND gt.hr = bdt.hr
WHERE bdt.on_delirium_med = 1  -- 只显示使用谵妄药物的患者
ORDER BY gt.stay_id, gt.hr
LIMIT 50;