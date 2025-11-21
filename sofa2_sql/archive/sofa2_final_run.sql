-- =================================================================
-- SOFA2 最终执行版本 - 使用优化配置直接创建表
-- =================================================================

-- 性能优化配置
SET work_mem = '2047MB';
SET maintenance_work_mem = '2047MB';
SET effective_cache_size = '70GB';
SET max_parallel_workers = 24;
SET max_parallel_workers_per_gather = 12;
SET parallel_leader_participation = on;
SET parallel_tuple_cost = 0.1;
SET parallel_setup_cost = 1000;
SET random_page_cost = 1.1;
SET seq_page_cost = 1.0;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
SET enable_parallel_append = on;
SET enable_parallel_hash = on;
SET jit = off;
SET statement_timeout = '14400s';
SET lock_timeout = '7200s';

-- 显示配置
SELECT 'SOFA2 优化配置' AS status,
       current_setting('work_mem') AS work_mem,
       current_setting('max_parallel_workers_per_gather') AS parallel_workers;

-- 创建最终优化表
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores_v3 CASCADE;

CREATE TABLE mimiciv_derived.sofa2_scores_v3 AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
),

-- 镇静药物检测
sedation_params AS (
    SELECT UNNEST(ARRAY['%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
                      '%dexmedetomidine%', '%ketamine%', '%clonidine%', '%etomidate%']) AS pattern
),

sedation_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE WHEN pr.drug ILIKE ANY (SELECT pattern FROM sedation_params)
                  AND pr.starttime <= co.endtime
                  AND COALESCE(pr.stoptime, co.endtime) >= co.starttime
                  AND pr.route IN ('IV DRIP', 'IV', 'Intravenous')
             THEN 1 ELSE 0 END) AS has_sedation
    FROM co
    LEFT JOIN mimiciv_hosp.prescriptions pr ON co.hadm_id = pr.hadm_id
    GROUP BY co.stay_id, co.hr
),

-- GCS评分
gcs_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN gcs.gcs <= 5 THEN 4
            WHEN gcs.gcs <= 8 THEN 3
            WHEN gcs.gcs <= 12 THEN 2
            WHEN gcs.gcs <= 14 THEN 1
            ELSE 0
        END) AS brain
    FROM co
    LEFT JOIN mimiciv_derived.gcs gcs
        ON co.stay_id = gcs.stay_id
        AND gcs.charttime <= co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 呼吸系统
respiratory_score AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN bg_min.pao2fio2ratio <= 100 THEN 4
            WHEN bg_min.pao2fio2ratio <= 200 THEN 3
            WHEN bg_min.pao2fio2ratio <= 300 THEN 2
            WHEN bg_min.pao2fio2ratio <= 400 THEN 1
            ELSE 0
        END AS respiratory
    FROM co
    LEFT JOIN LATERAL (
        SELECT MIN(bg.pao2fio2ratio) AS pao2fio2ratio
        FROM mimiciv_derived.bg bg
        WHERE bg.subject_id = co.subject_id
          AND bg.charttime >= co.starttime
          AND bg.charttime < co.endtime
          AND bg.specimen = 'ART.'
          AND bg.pao2fio2ratio > 0
    ) bg_min ON TRUE
),

-- 心血管系统
cardiovascular_score AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MAX(CASE WHEN va.norepinephrine > 0 OR va.epinephrine > 0 THEN 1 ELSE 0 END) > 0 THEN 4
            WHEN MAX(CASE WHEN va.dopamine > 15 THEN 1 ELSE 0 END) > 0 THEN 3
            WHEN MAX(CASE WHEN va.dopamine > 0 OR va.dobutamine > 0 THEN 1 ELSE 0 END) > 0 THEN 2
            ELSE 0
        END AS cardiovascular
    FROM co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) >= co.starttime
    GROUP BY co.stay_id, co.hr
),

-- 肝脏系统
liver_score AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MAX(enz.bilirubin_total) > 12.0 THEN 4
            WHEN MAX(enz.bilirubin_total) > 6.0 THEN 3
            WHEN MAX(enz.bilirubin_total) > 2.0 THEN 2
            WHEN MAX(enz.bilirubin_total) > 1.2 THEN 1
            ELSE 0
        END AS liver
    FROM co
    LEFT JOIN mimiciv_derived.enzyme enz
        ON co.hadm_id = enz.hadm_id
        AND enz.charttime >= co.starttime
        AND enz.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 肾脏系统
kidney_score AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MAX(rrt.dialysis_present) > 0 THEN 4
            WHEN MAX(chem.creatinine) > 5.0 THEN 4
            WHEN MAX(chem.creatinine) > 3.5 THEN 3
            WHEN MAX(chem.creatinine) > 2.0 THEN 2
            WHEN MAX(chem.creatinine) > 1.2 THEN 1
            ELSE 0
        END AS kidney
    FROM co
    LEFT JOIN mimiciv_derived.chemistry chem
        ON co.hadm_id = chem.hadm_id
        AND chem.charttime >= co.starttime
        AND chem.charttime < co.endtime
    LEFT JOIN mimiciv_derived.rrt rrt
        ON co.stay_id = rrt.stay_id
        AND rrt.charttime >= co.starttime
        AND rrt.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 凝血系统
hemostasis_score AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MIN(cbc.platelet) <= 50 THEN 4
            WHEN MIN(cbc.platelet) <= 80 THEN 3
            WHEN MIN(cbc.platelet) <= 100 THEN 2
            WHEN MIN(cbc.platelet) <= 150 THEN 1
            ELSE 0
        END AS hemostasis
    FROM co
    LEFT JOIN mimiciv_derived.complete_blood_count cbc
        ON co.hadm_id = cbc.hadm_id
        AND cbc.charttime >= co.starttime
        AND cbc.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

-- 最终结果
SELECT
    co.stay_id,
    co.hadm_id,
    co.subject_id,
    co.hr,
    co.starttime,
    co.endtime,
    COALESCE(gcs.brain, 0) AS brain,
    COALESCE(resp.respiratory, 0) AS respiratory,
    COALESCE(card.cardiovascular, 0) AS cardiovascular,
    COALESCE(liv.liver, 0) AS liver,
    COALESCE(kid.kidney, 0) AS kidney,
    COALESCE(hem.hemostasis, 0) AS hemostasis,
    (COALESCE(gcs.brain, 0) + COALESCE(resp.respiratory, 0) +
     COALESCE(card.cardiovascular, 0) + COALESCE(liv.liver, 0) +
     COALESCE(kid.kidney, 0) + COALESCE(hem.hemostasis, 0)) AS sofa2_total
FROM co
LEFT JOIN gcs_score gcs ON co.stay_id = gcs.stay_id AND co.hr = gcs.hr
LEFT JOIN respiratory_score resp ON co.stay_id = resp.stay_id AND co.hr = resp.hr
LEFT JOIN cardiovascular_score card ON co.stay_id = card.stay_id AND co.hr = card.hr
LEFT JOIN liver_score liv ON co.stay_id = liv.stay_id AND co.hr = liv.hr
LEFT JOIN kidney_score kid ON co.stay_id = kid.stay_id AND co.hr = kid.hr
LEFT JOIN hemostasis_score hem ON co.stay_id = hem.stay_id AND co.hr = hem.hr
WHERE co.hr >= 0;

-- 创建索引
ALTER TABLE mimiciv_derived.sofa2_scores_v3 ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;
CREATE INDEX idx_sofa2_v3_stay_id ON mimiciv_derived.sofa2_scores_v3(stay_id);
CREATE INDEX idx_sofa2_v3_total_score ON mimiciv_derived.sofa2_scores_v3(sofa2_total);

-- 显示结果
SELECT
    'SOFA2 V3 表创建完成' AS status,
    COUNT(*) AS total_records,
    COUNT(DISTINCT stay_id) AS unique_stays,
    ROUND(AVG(sofa2_total), 2) AS avg_score,
    MIN(sofa2_total) AS min_score,
    MAX(sofa2_total) AS max_score
FROM mimiciv_derived.sofa2_scores_v3;