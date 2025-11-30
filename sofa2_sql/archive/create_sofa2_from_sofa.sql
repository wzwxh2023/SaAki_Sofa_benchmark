-- =================================================================
-- 直接基于传统SOFA数据创建SOFA2评分表（简化版）
-- =================================================================

DROP TABLE IF EXISTS mimiciv_derived.sofa2_hourly_raw CASCADE;

CREATE TABLE mimiciv_derived.sofa2_hourly_raw AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
    WHERE hr >= 0 AND hr <= 23  -- 只看ICU入院后24小时
),

-- 直接复制传统SOFA评分到SOFA2
sofa_scores AS (
    SELECT
        co.stay_id,
        co.hr,
        co.starttime,
        co.endtime,
        fs.respiration AS respiratory_score,     -- 呼吸评分
        fs.coagulation AS hemostasis_score,     -- 凝血评分
        fs.liver AS liver_score,               -- 肝脏评分
        fs.cardiovascular AS cardiovascular_score, -- 心血管评分
        fs.cns AS brain_score,                -- 神经评分

        -- 肾脏评分：使用修复后的逻辑
        CASE
            WHEN fs.renal = 4 THEN 4
            WHEN fs.renal = 3 THEN 3
            WHEN fs.renal = 2 THEN 2
            WHEN fs.renal = 1 THEN 1
            ELSE 0
        END AS kidney_score
    FROM co
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON co.stay_id = fs.stay_id
)

-- 最终合并
SELECT
    stay_id,
    hadm_id,
    subject_id,
    hr,
    starttime,
    endtime,
    brain_score,
    respiratory_score,
    cardiovascular_score,
    liver_score,
    kidney_score,
    hemostasis_score
FROM sofa_scores;

CREATE INDEX idx_sofa2_from_sofa ON mimiciv_derived.sofa2_hourly_raw(stay_id, hr);

-- 创建验证查询
SELECT
    'SOFA2 Created from Traditional SOFA' as status,
    COUNT(DISTINCT stay_id) as total_patients,
    COUNT(*) as total_hourly_records,
    hr,
    COUNT(*) as records_per_hour
FROM mimiciv_derived.sofa2_hourly_raw
GROUP BY hr
ORDER BY hr;