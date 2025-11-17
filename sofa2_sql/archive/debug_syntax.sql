-- 诊断语法问题的脚本
-- 逐步测试每个CTE

-- 测试1: 基础CTE
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        -- start/endtime for this hour
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
)
SELECT COUNT(*) AS co_test FROM co LIMIT 5;