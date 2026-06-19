-- =================================================================
-- 步骤 4: 计算 24小时滑动窗口最差分 (Final Aggregation)
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores;

CREATE TABLE mimiciv_derived.sofa2_scores AS
WITH windowed AS (
    SELECT
        stay_id, hadm_id, subject_id, hr, starttime, endtime,
        COALESCE(MAX(brain_score) OVER w, 0) AS brain,
        COALESCE(MAX(respiratory_score) OVER w, 0) AS respiratory,
        COALESCE(MAX(cardiovascular_score) OVER w, 0) AS cardiovascular,
        COALESCE(MAX(kidney_score) OVER w, 0) AS kidney,
        COALESCE(MAX(liver_score) OVER w, 0) AS liver_strict24,
        COALESCE(MAX(hemostasis_score) OVER w, 0) AS hemostasis_strict24,
        COALESCE(MAX(liver_lab48_candidate) OVER w, 0) AS liver_full48_exploratory,
        COALESCE(MAX(hemostasis_lab48_candidate) OVER w, 0) AS hemostasis_full48_exploratory,
        (MAX((bilirubin_strict_available)::int) OVER w) = 1 AS bilirubin_strict24_has_evidence,
        (MAX((platelet_strict_available)::int) OVER w) = 1 AS platelet_strict24_has_evidence,
        liver_lab48_candidate,
        hemostasis_lab48_candidate
    FROM mimiciv_derived.sofa2_hourly_raw
    WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)
),
scored AS (
    SELECT
        *,
        CASE
            WHEN bilirubin_strict24_has_evidence THEN liver_strict24
            ELSE GREATEST(liver_strict24, COALESCE(liver_lab48_candidate, 0))
        END AS liver_lab48_rescue,
        CASE
            WHEN platelet_strict24_has_evidence THEN hemostasis_strict24
            ELSE GREATEST(hemostasis_strict24, COALESCE(hemostasis_lab48_candidate, 0))
        END AS hemostasis_lab48_rescue
    FROM windowed
)
SELECT
    stay_id, hadm_id, subject_id, hr, starttime, endtime,
    brain,
    respiratory,
    cardiovascular,
    liver_lab48_rescue AS liver,
    kidney,
    hemostasis_lab48_rescue AS hemostasis,
    (
        brain + respiratory + cardiovascular + kidney
        + liver_lab48_rescue + hemostasis_lab48_rescue
    ) AS sofa2_total,
    (
        brain + respiratory + cardiovascular + kidney
        + liver_strict24 + hemostasis_strict24
    ) AS sofa2_total_strict24,
    (
        brain + respiratory + cardiovascular + kidney
        + liver_lab48_rescue + hemostasis_lab48_rescue
    ) AS sofa2_total_lab48_rescue,
    (
        brain + respiratory + cardiovascular + kidney
        + liver_full48_exploratory + hemostasis_full48_exploratory
    ) AS sofa2_total_full48_exploratory,
    liver_strict24,
    liver_lab48_rescue,
    liver_full48_exploratory,
    hemostasis_strict24,
    hemostasis_lab48_rescue,
    hemostasis_full48_exploratory,
    platelet_strict24_has_evidence,
    bilirubin_strict24_has_evidence,
    (NOT platelet_strict24_has_evidence AND hemostasis_lab48_candidate IS NOT NULL) AS platelet_lab48_rescue_used,
    (NOT bilirubin_strict24_has_evidence AND liver_lab48_candidate IS NOT NULL) AS bilirubin_lab48_rescue_used
FROM scored;

-- 添加索引和主键
ALTER TABLE mimiciv_derived.sofa2_scores ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;
CREATE INDEX idx_sofa2_final_stay ON mimiciv_derived.sofa2_scores(stay_id);
COMMENT ON TABLE mimiciv_derived.sofa2_scores IS
    'SOFA-2 Scores (JAMA 2025). Primary sofa2_total uses platelet/bilirubin lab48_rescue plus official urine_output_rate kidney scoring.';

-- 显示最终结果
SELECT 'SOFA2 Calculation Complete' as status, COUNT(*) as total_rows FROM mimiciv_derived.sofa2_scores;
