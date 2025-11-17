-- 步骤2：添加更多基础CTE，包括修复过的chemistry和bg查询

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        -- start/endtime for this hour
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 24
)

-- 修复后的chemistry查询
, cr AS (
    SELECT co.stay_id, co.hr
        , MAX(chem.creatinine) AS creatinine_max
        , MAX(chem.potassium) AS potassium_max
    FROM co
    LEFT JOIN mimiciv_derived.chemistry chem
        ON co.hadm_id = chem.hadm_id
            AND co.starttime < chem.charttime
            AND co.endtime >= chem.charttime
    GROUP BY co.stay_id, co.hr
)

-- 修复后的bg查询
, bg_metabolic AS (
    SELECT co.stay_id, co.hr
        , MIN(bg.ph) AS ph_min
        , MIN(bg.bicarbonate) AS bicarbonate_min
    FROM co
    LEFT JOIN mimiciv_derived.bg bg
        ON co.subject_id = bg.subject_id
            AND bg.specimen = 'ART.'
            AND co.starttime < bg.charttime
            AND co.endtime >= bg.charttime
    GROUP BY co.stay_id, co.hr
)

-- 测试修复后的表关联
SELECT
    COUNT(*) AS total_hours,
    COUNT(cr.stay_id) AS hours_with_chemistry,
    COUNT(bg_metabolic.stay_id) AS hours_with_bg,
    AVG(cr.creatinine_max) AS avg_creatinine,
    AVG(bg_metabolic.ph_min) AS avg_ph
FROM co
LEFT JOIN cr ON co.stay_id = cr.stay_id AND co.hr = cr.hr
LEFT JOIN bg_metabolic ON co.stay_id = bg_metabolic.stay_id AND co.hr = bg_metabolic.hr
LIMIT 5;