-- =================================================================
-- 07: 基于 SOFA2 的 Sepsis-3 定义（加入 ΔSOFA 计算）
-- 参考 origin_sofa_sql/sepsis3.sql：
--   - 感染窗口：疑似感染时间前48小时至后24小时
--   - 官方简化假设基线 SOFA=0，这里显式计算基线，并在缺失时回退为0
-- 判定逻辑：
--   1) 窗口内存在疑似感染（suspected_infection=1）
--   2) ΔSOFA2 = (窗口内最大 SOFA2) - (前48小时内最小 SOFA2) >= 2
--   3) 取满足条件的最早事件（感染时间优先，其次 SOFA 时间）
-- 产出表：mimiciv_derived.sepsis3_sofa2_delta
-- =================================================================

DROP TABLE IF EXISTS mimiciv_derived.sepsis3_sofa2_delta CASCADE;

CREATE TABLE mimiciv_derived.sepsis3_sofa2_delta AS
WITH soi AS (
    SELECT
        subject_id,
        stay_id,
        hadm_id,
        ab_id,
        antibiotic,
        antibiotic_time,
        culture_time,
        suspected_infection,
        suspected_infection_time,
        specimen,
        positive_culture
    FROM mimiciv_derived.suspicion_of_infection
    WHERE stay_id IS NOT NULL
),
sofa2 AS (
    SELECT
        stay_id,
        starttime,
        endtime,
        brain,
        respiratory,
        cardiovascular,
        liver,
        kidney,
        hemostasis,
        sofa2_total AS sofa2_score
    FROM mimiciv_derived.sofa2_scores_hr_filtered
),
baseline AS (
    -- 基线 SOFA2：疑似感染时间前 48 小时内的最小 SOFA2
    SELECT
        soi.subject_id,
        soi.stay_id,
        soi.hadm_id,
        soi.suspected_infection_time,
        MIN(s2.sofa2_score) AS baseline_sofa2,
        COUNT(*) > 0 AS baseline_observed
    FROM soi
    LEFT JOIN sofa2 s2
        ON soi.stay_id = s2.stay_id
       AND s2.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
       AND s2.endtime <  soi.suspected_infection_time
    GROUP BY soi.subject_id, soi.stay_id, soi.hadm_id, soi.suspected_infection_time
),
window_scores AS (
    -- 感染窗口 (-48h, +24h) 内的 SOFA2，计算 ΔSOFA2
    SELECT
        soi.subject_id,
        soi.stay_id,
        soi.hadm_id,
        soi.ab_id,
        soi.antibiotic,
        soi.antibiotic_time,
        soi.culture_time,
        soi.suspected_infection,
        soi.suspected_infection_time,
        soi.specimen,
        soi.positive_culture,
        s2.endtime AS sofa_time,
        s2.sofa2_score,
        s2.brain,
        s2.respiratory,
        s2.cardiovascular,
        s2.liver,
        s2.kidney,
        s2.hemostasis,
        COALESCE(baseline.baseline_sofa2, 0) AS baseline_sofa2,
        COALESCE(baseline.baseline_sofa2, 0) AS baseline_sofa2_filled,
        baseline.baseline_observed,
        s2.sofa2_score - COALESCE(baseline.baseline_sofa2, 0) AS delta_sofa2,
        (s2.sofa2_score - COALESCE(baseline.baseline_sofa2, 0) >= 2 AND soi.suspected_infection = 1) AS sepsis3_sofa2
    FROM soi
    INNER JOIN sofa2 s2
        ON soi.stay_id = s2.stay_id
       AND s2.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
       AND s2.endtime <= soi.suspected_infection_time + INTERVAL '24 hours'
    LEFT JOIN baseline
        ON soi.stay_id = baseline.stay_id
       AND soi.subject_id = baseline.subject_id
       AND soi.hadm_id = baseline.hadm_id
       AND soi.suspected_infection_time = baseline.suspected_infection_time
),
first_hit AS (
    SELECT
        ws.*,
        ROW_NUMBER() OVER (
            PARTITION BY ws.stay_id
            ORDER BY
                ws.suspected_infection_time,
                ws.antibiotic_time,
                ws.culture_time,
                ws.sofa_time
        ) AS rn
    FROM window_scores ws
    WHERE ws.sepsis3_sofa2
)
SELECT
    subject_id,
    stay_id,
    hadm_id,
    ab_id,
    antibiotic,
    antibiotic_time,
    culture_time,
    suspected_infection_time,
    sofa_time,
    sofa2_score,
    baseline_sofa2,
    baseline_observed,
    delta_sofa2,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    sepsis3_sofa2
FROM first_hit
WHERE rn = 1;

COMMENT ON TABLE mimiciv_derived.sepsis3_sofa2_delta IS 'Sepsis-3 onset using SOFA2 with explicit ΔSOFA2 (baseline=48h pre-infection min, fallback 0)';
