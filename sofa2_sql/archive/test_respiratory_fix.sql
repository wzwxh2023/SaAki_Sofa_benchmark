-- 简单测试脚本，验证修复后的呼吸评分逻辑
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

, advanced_resp_support AS (
    -- Advanced support from ventilation table
    SELECT
        stay_id,
        starttime,
        endtime,
        ventilation_status,
        1 AS has_advanced_support
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')

    UNION ALL

    -- Add CPAP/BiPAP support from chartevents
    SELECT
        ce.stay_id,
        ce.charttime AS starttime,
        ce.charttime AS endtime,
        CASE
            WHEN ce.itemid IN (227583) THEN 'CPAP'  -- Autoset/CPAP
            WHEN ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582) THEN 'BiPAP'
            ELSE 'Other_NIV'
        END AS ventilation_status,
        1 AS has_advanced_support
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582, 227583)
      AND ce.valuenum IS NOT NULL
      AND (ce.valuenum > 0 OR ce.value IS NOT NULL)
)

, spo2_data AS (
    SELECT
        ie.stay_id,
        ce.charttime,
        CASE
            WHEN ce.valuenum IS NOT NULL AND ce.valuenum > 0
            THEN CAST(ce.valuenum AS NUMERIC)
            ELSE NULL
        END AS spo2
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.chartevents ce
        ON ie.stay_id = ce.stay_id
    WHERE ce.itemid = 220227
      AND ce.valuenum IS NOT NULL
      AND ce.valuenum > 0
      AND ce.valuenum < 100
)

, fio2_chart_data AS (
    SELECT
        ie.stay_id,
        ce.charttime,
        CASE
            WHEN ce.valueuom = '%' AND ce.valuenum IS NOT NULL
            THEN CAST(ce.valuenum AS NUMERIC) / 100
            WHEN ce.valuenum IS NOT NULL AND ce.valuenum <= 1
            THEN CAST(ce.valuenum AS NUMERIC)
            WHEN ce.valuenum IS NOT NULL AND ce.valuenum > 1
            THEN CAST(ce.valuenum AS NUMERIC) / 100
            ELSE NULL
        END AS fio2
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.chartevents ce
        ON ie.stay_id = ce.stay_id
    WHERE ce.itemid IN (229841, 229280, 230086)
      AND ce.valuenum IS NOT NULL
      AND ce.valuenum > 0
      AND ce.valuenum <= 100
)

SELECT
    COUNT(*) AS total_hours,
    COUNT(DISTINCT co.stay_id) AS unique_stays
FROM co
WHERE co.hr >= 0
LIMIT 10;