-- =================================================================
-- 05: 过滤 SOFA2 评分，去除 hr<0 的异常行
-- 逻辑: 基于 mimiciv_derived.sofa2_scores，仅保留 hr >= 0 的记录
-- 输出: mimiciv_derived.sofa2_scores_hr_filtered
-- =================================================================

DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores_hr_filtered CASCADE;

CREATE TABLE mimiciv_derived.sofa2_scores_hr_filtered AS
SELECT *
FROM mimiciv_derived.sofa2_scores
WHERE hr >= 0;

CREATE INDEX idx_sofa2_scores_hr_filtered_stay_hr
    ON mimiciv_derived.sofa2_scores_hr_filtered (stay_id, hr);

COMMENT ON TABLE mimiciv_derived.sofa2_scores_hr_filtered IS 'SOFA2 scores filtered to hr >= 0';
