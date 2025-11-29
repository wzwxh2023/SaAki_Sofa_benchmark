-- =================================================================
-- 创建first_day_sofa2表
-- 使用ICU入院后0-23小时的SOFA2评分（24小时窗口）
-- =================================================================

-- 创建first_day_sofa2表
CREATE TABLE mimiciv_derived.first_day_sofa2 AS
WITH

-- 获取ICU入院时间
icu_intime AS (
    SELECT
        stay_id,
        subject_id,
        hadm_id,
        intime
    FROM mimiciv_icu.icustays
),

-- 直接使用已有的hr字段（hr已经是相对于ICU入院的小时偏移）
sofa2_with_hour_offset AS (
    SELECT
        s.stay_id,
        s.subject_id,
        s.hadm_id,
        s.hr,
        s.starttime,
        s.endtime,
        s.brain,
        s.respiratory,
        s.cardiovascular,
        s.liver,
        s.kidney,
        s.hemostasis,
        s.sofa2_total
    FROM mimiciv_derived.sofa2_scores_hr_filtered s
    JOIN icu_intime i ON s.stay_id = i.stay_id
),

-- 筛选0-23小时的记录作为first day
sofa2_first_day AS (
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
        -- 取0-23小时内的最高总分
        MAX(sofa2_total) AS sofa2_total
    FROM sofa2_with_hour_offset
    WHERE hr BETWEEN 0 AND 23  -- ICU入院后24小时（0-23小时）
    GROUP BY stay_id, subject_id, hadm_id
)

-- 主查询
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
    sofa2_total

FROM sofa2_first_day;

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
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.sofa2_total IS 'Maximum total SOFA2 score in first 24 hours';