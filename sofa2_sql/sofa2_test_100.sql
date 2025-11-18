-- =================================================================
-- SOFA-2 评分系统测试版本 - 100个样本
-- 用于测试脚本语法和逻辑正确性
-- =================================================================

WITH co AS (
    -- 限制为前100个ICU住院进行测试
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ie.stay_id IN (
        SELECT stay_id
        FROM mimiciv_icu.icustays
        ORDER BY stay_id
        LIMIT 100
    )
),

-- =================================================================
-- 预处理步骤 (Staging CTEs)
-- =================================================================

-- 步骤1: 预处理药物列表
drug_params AS (
    SELECT UNNEST(ARRAY[
        '%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
        '%fentanyl%', '%remifentanil%', '%morphine%', '%hydromorphone%',
        '%dexmedetomidine%', '%ketamine%', '%clonidine%', '%etomidate%'
    ]) AS sedation_pattern
),
delirium_params AS (
    SELECT UNNEST(ARRAY[
        '%haloperidol%', '%haldol%', '%quetiapine%', '%seroquel%',
        '%olanzapine%', '%zyprexa%', '%risperidone%', '%risperdal%',
        '%ziprasidone%', '%geodon%', '%clozapine%', '%aripiprazole%'
    ]) AS delirium_pattern
),

-- 步骤2: 预处理GCS数据
gcs_stg AS (
    SELECT
        gcs.stay_id,
        gcs.charttime,
        CASE
            WHEN gcs.gcs < 3 THEN 3
            WHEN gcs.gcs > 15 THEN 15
            ELSE gcs.gcs
        END AS gcs
    FROM mimiciv_derived.gcs gcs
    WHERE gcs.stay_id IN (SELECT stay_id FROM co)
),

-- 步骤3: 简化的血气数据
bg_stg AS (
    SELECT
        bg.subject_id,
        bg.charttime,
        bg.pao2fio2ratio
    FROM mimiciv_derived.bg bg
    WHERE bg.subject_id IN (SELECT subject_id FROM co)
        AND bg.specimen = 'ART.'
),

-- 步骤4: 简化的呼吸支持数据
vent_stg AS (
    SELECT
        v.stay_id,
        v.starttime,
        v.endtime,
        v.ventilation_status
    FROM mimiciv_derived.ventilation v
    WHERE v.stay_id IN (SELECT stay_id FROM co)
        AND v.ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')
),

-- 步骤5: 简化的生命体征数据
vitals_stg AS (
    SELECT
        v.stay_id,
        v.charttime,
        v.mbp
    FROM mimiciv_derived.vitalsign v
    WHERE v.stay_id IN (SELECT stay_id FROM co)
),

-- 步骤6: 简化的血管活性药物数据
vaso_stg AS (
    SELECT ie.stay_id, 'norepinephrine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.norepinephrine mv
        ON ie.stay_id = mv.stay_id
    WHERE ie.stay_id IN (SELECT stay_id FROM co)
    UNION ALL
    SELECT ie.stay_id, 'epinephrine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.epinephrine mv
        ON ie.stay_id = mv.stay_id
    WHERE ie.stay_id IN (SELECT stay_id FROM co)
    UNION ALL
    SELECT ie.stay_id, 'dobutamine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.dobutamine mv
        ON ie.stay_id = mv.stay_id
    WHERE ie.stay_id IN (SELECT stay_id FROM co)
    UNION ALL
    SELECT ie.stay_id, 'dopamine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.dopamine mv
        ON ie.stay_id = mv.stay_id
    WHERE ie.stay_id IN (SELECT stay_id FROM co)
),

-- 步骤7: 实验室数据已经在derived表中预处理，直接跳过
-- labs_stg AS (
--     实验室数据将直接从derived表中获取
-- ),

-- =================================================================
-- 主要计算逻辑
-- =================================================================

-- 脑神经系统评分
brain_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(gcs_stg.gcs) AS gcs_min
    FROM co
    LEFT JOIN gcs_stg
        ON co.stay_id = gcs_stg.stay_id
        AND co.starttime < gcs_stg.charttime
        AND co.endtime >= gcs_stg.charttime
    GROUP BY co.stay_id, co.hr
),

-- 呼吸系统评分
respiratory_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(CASE
            WHEN vent_stg.stay_id IS NULL THEN bg_stg.pao2fio2ratio
            ELSE NULL
        END) AS pao2fio2_novent_min,
        MIN(CASE
            WHEN vent_stg.stay_id IS NOT NULL THEN bg_stg.pao2fio2ratio
            ELSE NULL
        END) AS pao2fio2_vent_min
    FROM co
    LEFT JOIN bg_stg
        ON co.subject_id = bg_stg.subject_id
        AND co.starttime < bg_stg.charttime
        AND co.endtime >= bg_stg.charttime
    LEFT JOIN vent_stg
        ON co.stay_id = vent_stg.stay_id
        AND bg_stg.charttime >= vent_stg.starttime
        AND bg_stg.charttime <= vent_stg.endtime
    GROUP BY co.stay_id, co.hr
),

-- 心血管系统评分
cardiovascular_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(vitals_stg.mbp) AS mbp_min,
        MAX(CASE WHEN vaso_stg.treatment = 'norepinephrine' THEN vaso_stg.rate END) AS rate_norepinephrine,
        MAX(CASE WHEN vaso_stg.treatment = 'epinephrine' THEN vaso_stg.rate END) AS rate_epinephrine,
        MAX(CASE WHEN vaso_stg.treatment = 'dopamine' THEN vaso_stg.rate END) AS rate_dopamine,
        MAX(CASE WHEN vaso_stg.treatment = 'dobutamine' THEN vaso_stg.rate END) AS rate_dobutamine
    FROM co
    LEFT JOIN vitals_stg
        ON co.stay_id = vitals_stg.stay_id
        AND co.starttime < vitals_stg.charttime
        AND co.endtime >= vitals_stg.charttime
    LEFT JOIN vaso_stg
        ON co.stay_id = vaso_stg.stay_id
    GROUP BY co.stay_id, co.hr
),

-- 肝脏系统评分
liver_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(enz.bilirubin_total) AS bilirubin_max
    FROM co
    LEFT JOIN mimiciv_derived.enzyme enz
        ON co.hadm_id = enz.hadm_id
        AND co.starttime < enz.charttime
        AND co.endtime >= enz.charttime
    GROUP BY co.stay_id, co.hr
),

-- 肾脏系统评分
kidney_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(chem.creatinine) AS creatinine_max
    FROM co
    LEFT JOIN mimiciv_derived.chemistry chem
        ON co.hadm_id = chem.hadm_id
        AND co.starttime < chem.charttime
        AND co.endtime >= chem.charttime
    GROUP BY co.stay_id, co.hr
),

-- 凝血系统评分
hemostasis_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(cbc.platelet) AS platelet_min
    FROM co
    LEFT JOIN mimiciv_derived.complete_blood_count cbc
        ON co.hadm_id = cbc.hadm_id
        AND co.starttime < cbc.charttime
        AND co.endtime >= cbc.charttime
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- 计算最终评分
-- =================================================================

scorecalc AS (
    SELECT
        co.stay_id,
        co.subject_id,
        co.hadm_id,
        co.hr,
        co.starttime,
        co.endtime,

        -- 神经系统评分
        CASE
            WHEN brain.gcs_min <= 5 THEN 4
            WHEN brain.gcs_min >= 6 AND brain.gcs_min <= 8 THEN 3
            WHEN brain.gcs_min >= 9 AND brain.gcs_min <= 12 THEN 2
            WHEN brain.gcs_min >= 13 AND brain.gcs_min <= 14 THEN 1
            WHEN brain.gcs_min = 15 THEN 0
            ELSE NULL
        END AS brain,

        -- 呼吸系统评分（简化版）
        CASE
            WHEN respiratory.pao2fio2_vent_min <= 75 THEN 4
            WHEN respiratory.pao2fio2_vent_min <= 150 THEN 3
            WHEN respiratory.pao2fio2_novent_min <= 225 THEN 2
            WHEN respiratory.pao2fio2_novent_min <= 300 THEN 1
            ELSE 0
        END AS respiratory,

        -- 心血管系统评分
        CASE
            WHEN cardiovascular.rate_norepinephrine > 0.1 OR cardiovascular.rate_epinephrine > 0.1 THEN 4
            WHEN cardiovascular.rate_dopamine > 15 OR cardiovascular.rate_norepinephrine > 0 OR cardiovascular.rate_epinephrine > 0 THEN 3
            WHEN cardiovascular.rate_dobutamine > 0 OR cardiovascular.rate_dopamine > 0 THEN 2
            WHEN cardiovascular.mbp_min < 70 THEN 1
            ELSE 0
        END AS cardiovascular,

        -- 肝脏系统评分
        CASE
            WHEN liver.bilirubin_max > 12.0 THEN 4
            WHEN liver.bilirubin_max > 6.0 THEN 3
            WHEN liver.bilirubin_max > 3.0 THEN 2
            WHEN liver.bilirubin_max > 1.2 THEN 1
            ELSE 0
        END AS liver,

        -- 肾脏系统评分
        CASE
            WHEN kidney.creatinine_max > 5.0 THEN 4
            WHEN kidney.creatinine_max > 3.5 THEN 3
            WHEN kidney.creatinine_max > 2.0 THEN 2
            WHEN kidney.creatinine_max > 1.2 THEN 1
            ELSE 0
        END AS kidney,

        -- 凝血系统评分
        CASE
            WHEN hemostasis.platelet_min <= 50 THEN 4
            WHEN hemostasis.platelet_min <= 80 THEN 3
            WHEN hemostasis.platelet_min <= 100 THEN 2
            WHEN hemostasis.platelet_min <= 150 THEN 1
            ELSE 0
        END AS hemostasis

    FROM co
    LEFT JOIN brain_score brain ON co.stay_id = brain.stay_id AND co.hr = brain.hr
    LEFT JOIN respiratory_score respiratory ON co.stay_id = respiratory.stay_id AND co.hr = respiratory.hr
    LEFT JOIN cardiovascular_score cardiovascular ON co.stay_id = cardiovascular.stay_id AND co.hr = cardiovascular.hr
    LEFT JOIN liver_score liver ON co.stay_id = liver.stay_id AND co.hr = liver.hr
    LEFT JOIN kidney_score kidney ON co.stay_id = kidney.stay_id AND co.hr = kidney.hr
    LEFT JOIN hemostasis_score hemostasis ON co.stay_id = hemostasis.stay_id AND co.hr = hemostasis.hr
),

-- =================================================================
-- 24小时滚动窗口评分计算
-- =================================================================

score_final AS (
    SELECT
        scorecalc.*,
        -- 使用窗口函数计算24小时滚动窗口内的最大值
        MAX(brain) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS brain_24hours,
        MAX(respiratory) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS respiratory_24hours,
        MAX(cardiovascular) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS cardiovascular_24hours,
        MAX(liver) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS liver_24hours,
        MAX(kidney) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS kidney_24hours,
        MAX(hemostasis) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS hemostasis_24hours,
        -- 计算总分
        COALESCE(MAX(brain) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ), 0) +
        COALESCE(MAX(respiratory) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ), 0) +
        COALESCE(MAX(cardiovascular) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ), 0) +
        COALESCE(MAX(liver) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ), 0) +
        COALESCE(MAX(kidney) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ), 0) +
        COALESCE(MAX(hemostasis) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ), 0) AS sofa2_24hours
    FROM scorecalc
    WHERE hr >= 0
)

-- =================================================================
-- 测试输出 - 仅显示前20行结果
-- =================================================================
SELECT
    stay_id,
    subject_id,
    hadm_id,
    hr,
    starttime,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    brain_24hours,
    respiratory_24hours,
    cardiovascular_24hours,
    liver_24hours,
    kidney_24hours,
    hemostasis_24hours,
    sofa2_24hours
FROM score_final
ORDER BY stay_id, hr
LIMIT 20;