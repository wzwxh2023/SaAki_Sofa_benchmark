-- =================================================================
-- 创建first_day_sofa2表（简化版）
-- 使用ICU入院后0-23小时的SOFA2评分（24小时窗口）
-- =================================================================

-- 删除已存在的表
DROP TABLE IF EXISTS mimiciv_derived.first_day_sofa2 CASCADE;

-- 创建表
CREATE TABLE mimiciv_derived.first_day_sofa2 AS
WITH organ_max AS (
SELECT
    stay_id,
    subject_id,
    hadm_id,
    -- 取0-23小时内各系统的最高分
    MAX(brain) AS brain,
    MAX(respiratory) AS respiratory,
    MAX(cardiovascular) AS cardiovascular,
    MAX(liver) AS liver,
    MAX(kidney) AS kidney,
    MAX(hemostasis) AS hemostasis,
    MAX(liver_lab48_rescue) AS liver_lab48_rescue,
    MAX(liver_strict24) AS liver_strict24,
    MAX(liver_full48_exploratory) AS liver_full48_exploratory,
    MAX(hemostasis_lab48_rescue) AS hemostasis_lab48_rescue,
    MAX(hemostasis_strict24) AS hemostasis_strict24,
    MAX(hemostasis_full48_exploratory) AS hemostasis_full48_exploratory,
    BOOL_OR(platelet_lab48_rescue_used) AS platelet_lab48_rescue_used,
    BOOL_OR(bilirubin_lab48_rescue_used) AS bilirubin_lab48_rescue_used
FROM mimiciv_derived.sofa2_scores_hr_filtered
WHERE hr BETWEEN 0 AND 23  -- ICU入院后24小时（0-23小时）
GROUP BY stay_id, subject_id, hadm_id
)
SELECT
    stay_id,
    subject_id,
    hadm_id,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    -- First-day SOFA totals are SUM(per-organ first-day maxima), not MAX(hourly total).
    COALESCE(brain, 0) + COALESCE(respiratory, 0)
        + COALESCE(cardiovascular, 0) + COALESCE(kidney, 0)
        + COALESCE(liver_lab48_rescue, 0) + COALESCE(hemostasis_lab48_rescue, 0) AS sofa2_total,
    COALESCE(brain, 0) + COALESCE(respiratory, 0)
        + COALESCE(cardiovascular, 0) + COALESCE(kidney, 0)
        + COALESCE(liver_lab48_rescue, 0) + COALESCE(hemostasis_lab48_rescue, 0) AS sofa2_total_lab48_rescue,
    COALESCE(brain, 0) + COALESCE(respiratory, 0)
        + COALESCE(cardiovascular, 0) + COALESCE(kidney, 0)
        + COALESCE(liver_strict24, 0) + COALESCE(hemostasis_strict24, 0) AS sofa2_total_strict24,
    COALESCE(brain, 0) + COALESCE(respiratory, 0)
        + COALESCE(cardiovascular, 0) + COALESCE(kidney, 0)
        + COALESCE(liver_full48_exploratory, 0) + COALESCE(hemostasis_full48_exploratory, 0) AS sofa2_total_full48_exploratory,
    liver_lab48_rescue,
    liver_strict24,
    liver_full48_exploratory,
    hemostasis_lab48_rescue,
    hemostasis_strict24,
    hemostasis_full48_exploratory,
    platelet_lab48_rescue_used,
    bilirubin_lab48_rescue_used
FROM organ_max;

-- 创建索引
CREATE INDEX idx_first_day_sofa2_stay ON mimiciv_derived.first_day_sofa2(stay_id);
CREATE INDEX idx_first_day_sofa2_subject ON mimiciv_derived.first_day_sofa2(subject_id);
CREATE INDEX idx_first_day_sofa2_hadm ON mimiciv_derived.first_day_sofa2(hadm_id);
CREATE INDEX idx_first_day_sofa2_total ON mimiciv_derived.first_day_sofa2(sofa2_total);

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.first_day_sofa2 IS 'First day SOFA2 scores (0-23 hours after ICU admission)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.brain IS 'Maximum brain SOFA2 score in first 24 hours';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.respiratory IS 'Maximum respiratory SOFA2 score in first 24 hours';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.cardiovascular IS 'Maximum cardiovascular SOFA2 score in first 24 hours';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.liver IS 'Maximum liver SOFA2 score in first 24 hours';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.kidney IS 'Maximum kidney SOFA2 score in first 24 hours';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.hemostasis IS 'Maximum hemostasis SOFA2 score in first 24 hours';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.sofa2_total IS
    'First-day total SOFA2 score: sum of per-organ maxima in first 24 hours; primary policy is lab48_rescue_kidney_uorate';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.sofa2_total_lab48_rescue IS
    'Explicit primary SOFA2 total: platelet/bilirubin lab48_rescue plus official urine_output_rate kidney scoring';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.sofa2_total_strict24 IS
    'SOFA2 sensitivity total using strict 24h platelet/bilirubin evidence only';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.sofa2_total_full48_exploratory IS
    'SOFA2 exploratory total using unconditional 48h platelet/bilirubin lookback';
