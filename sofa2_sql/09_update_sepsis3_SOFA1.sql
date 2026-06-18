-- =================================================================
-- 09: 基于 SOFA 的 Sepsis-3 定义（采用 ΔSOFA 计算方式）
-- 与 sofa2_sql/07_sepsis3_sofa2_delta.sql 逻辑一致，但使用原始 SOFA 评分
--
-- 主要改进：
--   1. 采用显式 ΔSOFA 计算（而非假设基线=0）
--   2. 基线 SOFA：疑似感染时间前 48 小时内的最小 SOFA
--   3. 在缺失基线数据时回退为 0（保持与原始方法兼容）
--   4. 保留透明度，记录基线值和 ΔSOFA
--
-- 判定逻辑：
--   1) 窗口内存在疑似感染（suspected_infection=1）
--   2) ΔSOFA = (窗口内最大 SOFA) - (前48小时内最小 SOFA) >= 2
--   3) 取满足条件的最早事件（感染时间优先，其次 SOFA 时间）
--
-- 产出表：mimiciv_derived.sepsis3_sofa1_delta
-- =================================================================

DROP TABLE IF EXISTS mimiciv_derived.sepsis3_sofa1_delta CASCADE;

CREATE TABLE mimiciv_derived.sepsis3_sofa1_delta AS
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
sofa AS (
    -- 使用原始 SOFA 评分表
    SELECT
        stay_id,
        starttime,
        endtime,
        sofa_respiration_official_mimic_hourly AS respiration,
        sofa_coagulation_official_mimic_hourly AS coagulation,
        sofa_liver_official_mimic_hourly AS liver,
        sofa_cardiovascular_official_mimic_hourly AS cardiovascular,
        sofa_cns_official_mimic_hourly AS cns,
        sofa_renal_official_mimic_hourly AS renal,
        "SOFA" AS sofa_score
    FROM mimiciv_derived.sofa1_hourly_current
),
baseline AS (
    -- 基线 SOFA：疑似感染时间前 48 小时内的最小 SOFA
    SELECT
        soi.subject_id,
        soi.stay_id,
        soi.hadm_id,
        soi.suspected_infection_time,
        MIN(s.sofa_score) AS baseline_sofa,
        COUNT(*) > 0 AS baseline_observed
    FROM soi
    LEFT JOIN sofa s
        ON soi.stay_id = s.stay_id
       AND s.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
       AND s.endtime <  soi.suspected_infection_time
    GROUP BY soi.subject_id, soi.stay_id, soi.hadm_id, soi.suspected_infection_time
),
window_scores AS (
    -- 感染窗口 (-48h, +24h) 内的 SOFA，计算 ΔSOFA
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
        s.endtime AS sofa_time,
        s.sofa_score,
        s.respiration,
        s.coagulation,
        s.liver,
        s.cardiovascular,
        s.cns,
        s.renal,
        COALESCE(baseline.baseline_sofa, 0) AS baseline_sofa,
        COALESCE(baseline.baseline_sofa, 0) AS baseline_sofa_filled,
        baseline.baseline_observed,
        s.sofa_score - COALESCE(baseline.baseline_sofa, 0) AS delta_sofa,
        -- 两种 sepsis 定义方法
        (s.sofa_score - COALESCE(baseline.baseline_sofa, 0) >= 2 AND soi.suspected_infection = 1) AS sepsis3_sofa_delta,
        (s.sofa_score >= 2 AND soi.suspected_infection = 1) AS sepsis3_sofa_absolute
    FROM soi
    INNER JOIN sofa s
        ON soi.stay_id = s.stay_id
       AND s.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
       AND s.endtime <= soi.suspected_infection_time + INTERVAL '24 hours'
    LEFT JOIN baseline
        ON soi.stay_id = baseline.stay_id
       AND soi.subject_id = baseline.subject_id
       AND soi.hadm_id = baseline.hadm_id
       AND soi.suspected_infection_time = baseline.suspected_infection_time
),
first_hit AS (
    -- 取满足 ΔSOFA 条件的最早事件
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
    WHERE ws.sepsis3_sofa_delta
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
    sofa_score,
    baseline_sofa,
    baseline_observed,
    delta_sofa,
    respiration,
    coagulation,
    liver,
    cardiovascular,
    cns,
    renal,
    sepsis3_sofa_delta,
    sepsis3_sofa_absolute
FROM first_hit
WHERE rn = 1;

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.sepsis3_sofa1_delta IS 'Sepsis-3 onset using original SOFA with explicit ΔSOFA calculation (baseline=48h pre-infection min, fallback 0)';

-- 添加列注释
COMMENT ON COLUMN mimiciv_derived.sepsis3_sofa1_delta.baseline_sofa IS 'Baseline SOFA score (minimum in 48h before infection)';
COMMENT ON COLUMN mimiciv_derived.sepsis3_sofa1_delta.baseline_observed IS 'Whether baseline SOFA was observed (true) or imputed as 0 (false)';
COMMENT ON COLUMN mimiciv_derived.sepsis3_sofa1_delta.delta_sofa IS 'Change in SOFA score from baseline';
COMMENT ON COLUMN mimiciv_derived.sepsis3_sofa1_delta.sepsis3_sofa_delta IS 'Sepsis-3 defined by ΔSOFA ≥ 2';
COMMENT ON COLUMN mimiciv_derived.sepsis3_sofa1_delta.sepsis3_sofa_absolute IS 'Sepsis-3 defined by absolute SOFA ≥ 2 (for comparison)';
