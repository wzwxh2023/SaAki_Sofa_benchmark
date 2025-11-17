-- 步骤3：添加修复后的高级呼吸支持逻辑

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 24
)

-- 修复后的高级呼吸支持（包含CPAP/BiPAP）
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

-- 修复后的血气数据（包含stay_id）
, pafi AS (
    SELECT
        ie.stay_id,
        bg.charttime,
        -- Check if on advanced respiratory support during this blood gas
        CASE
            WHEN ars.stay_id IS NOT NULL THEN 1
            ELSE 0
        END AS on_advanced_support,
        bg.pao2fio2ratio
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.bg bg
        ON ie.subject_id = bg.subject_id
        AND bg.specimen = 'ART.'
    LEFT JOIN advanced_resp_support ars
        ON ie.stay_id = ars.stay_id
            AND bg.charttime >= ars.starttime
            AND bg.charttime <= ars.endtime
    WHERE ie.stay_id IN (SELECT stay_id FROM co LIMIT 1000)  -- 限制数据量
)

-- 测试修复后的呼吸支持逻辑
SELECT
    COUNT(*) AS total_bg_readings,
    COUNT(CASE WHEN on_advanced_support = 1 THEN 1 END) AS readings_with_support,
    COUNT(DISTINCT stay_id) AS unique_stays,
    AVG(pao2fio2ratio) AS avg_pf_ratio
FROM pafi
LIMIT 5;