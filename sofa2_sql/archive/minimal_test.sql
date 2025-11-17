-- 最小化测试SOFA2语法
WITH co AS (
    SELECT stay_id, hr, starttime, endtime
    FROM mimiciv_derived.icustay_hourly
    WHERE stay_id IN (30000834)
    LIMIT 5
),
respiratory AS (
    SELECT stay_id, hr, 0 AS respiratory
    FROM co
),
cardiovascular AS (
    SELECT stay_id, hr, 0 AS cardiovascular
    FROM co
)
SELECT 
    co.stay_id, 
    co.hr,
    respiratory.respiratory,
    cardiovascular.cardiovascular
FROM co
LEFT JOIN respiratory ON co.stay_id = respiratory.stay_id AND co.hr = respiratory.hr
LEFT JOIN cardiovascular ON co.stay_id = cardiovascular.stay_id AND co.hr = cardiovascular.hr
ORDER BY co.stay_id, co.hr;
