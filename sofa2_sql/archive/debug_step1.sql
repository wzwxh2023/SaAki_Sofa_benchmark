-- 步骤1：测试基础CTE（不包括任何我们添加的呼吸评分修复）

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        -- start/endtime for this hour
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 24  -- 限制到第一天
)

, patient_weight AS (
    SELECT
        stay_id,
        weight
    FROM mimiciv_derived.first_day_weight
    WHERE weight IS NOT NULL AND weight > 0
)

-- 测试基础连接
SELECT
    COUNT(*) AS total_hours,
    COUNT(DISTINCT co.stay_id) AS unique_stays,
    COUNT(DISTINCT patient_weight.stay_id) AS stays_with_weight
FROM co
LEFT JOIN patient_weight
    ON co.stay_id = patient_weight.stay_id
LIMIT 5;