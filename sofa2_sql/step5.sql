-- =================================================================
-- 步骤 4: 计算 24小时滑动窗口最差分 (Final Aggregation)
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores;

CREATE TABLE mimiciv_derived.sofa2_scores AS
SELECT
    stay_id, hadm_id, subject_id, hr, starttime, endtime,
    MAX(brain_score) OVER w AS brain,
    MAX(respiratory_score) OVER w AS respiratory,
    MAX(cardiovascular_score) OVER w AS cardiovascular,
    MAX(liver_score) OVER w AS liver,
    MAX(kidney_score) OVER w AS kidney,
    MAX(hemostasis_score) OVER w AS hemostasis,
    (MAX(brain_score) OVER w + MAX(respiratory_score) OVER w + MAX(cardiovascular_score) OVER w + MAX(liver_score) OVER w + MAX(kidney_score) OVER w + MAX(hemostasis_score) OVER w) AS sofa2_total
FROM mimiciv_derived.sofa2_hourly_raw
WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING);

-- 添加索引和主键
ALTER TABLE mimiciv_derived.sofa2_scores ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;
CREATE INDEX idx_sofa2_final_stay ON mimiciv_derived.sofa2_scores(stay_id);
COMMENT ON TABLE mimiciv_derived.sofa2_scores IS 'SOFA-2 Scores (JAMA 2025) - Finalized';

-- 显示最终结果
SELECT 'SOFA2 Calculation Complete' as status, COUNT(*) as total_rows FROM mimiciv_derived.sofa2_scores;