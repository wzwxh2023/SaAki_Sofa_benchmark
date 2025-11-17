-- 步骤4：添加SpO2:FiO2逻辑

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 24
        AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 100)  -- 限制数据量
)

-- 高级呼吸支持
, advanced_resp_support AS (
    SELECT
        stay_id,
        starttime,
        endtime,
        ventilation_status,
        1 AS has_advanced_support
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')

    UNION ALL

    SELECT
        ce.stay_id,
        ce.charttime AS starttime,
        ce.charttime AS endtime,
        CASE
            WHEN ce.itemid IN (227583) THEN 'CPAP'
            WHEN ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582) THEN 'BiPAP'
            ELSE 'Other_NIV'
        END AS ventilation_status,
        1 AS has_advanced_support
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582, 227583)
      AND ce.valuenum IS NOT NULL
      AND (ce.valuenum > 0 OR ce.value IS NOT NULL)
)

-- SpO2数据提取
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
    WHERE ce.itemid = 220227  -- "Arterial O2 Saturation"
      AND ce.valuenum IS NOT NULL
      AND ce.valuenum > 0
      AND ce.valuenum < 100
      AND ie.stay_id IN (SELECT stay_id FROM co)
)

-- FiO2数据提取
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
      AND ie.stay_id IN (SELECT stay_id FROM co)
)

-- SF比值计算
, sfi_data AS (
    SELECT
        co.stay_id,
        co.hr,
        AVG(spo2.spo2) AS spo2_avg,
        AVG(fio2.fio2) AS fio2_avg,
        CASE
            WHEN AVG(spo2.spo2) < 98 AND AVG(fio2.fio2) > 0 AND AVG(fio2.fio2) <= 1
            THEN AVG(spo2.spo2) / AVG(fio2.fio2)
            ELSE NULL
        END AS sfi_ratio,
        MAX(ars.has_advanced_support) AS has_advanced_support
    FROM co
    LEFT JOIN spo2_data spo2
        ON co.stay_id = spo2.stay_id
        AND co.starttime <= spo2.charttime
        AND co.endtime >= spo2.charttime
    LEFT JOIN fio2_chart_data fio2
        ON co.stay_id = fio2.stay_id
        AND co.starttime <= fio2.charttime
        AND co.endtime >= fio2.charttime
    LEFT JOIN advanced_resp_support ars
        ON co.stay_id = ars.stay_id
        AND co.starttime <= ars.starttime
        AND co.endtime >= ars.endtime
    GROUP BY co.stay_id, co.hr
)

-- 测试SpO2:FiO2逻辑
SELECT
    COUNT(*) AS total_hours,
    COUNT(CASE WHEN sfi_ratio IS NOT NULL THEN 1 END) AS hours_with_sf_ratio,
    COUNT(CASE WHEN spo2_avg < 98 THEN 1 END) AS hours_with_low_spo2,
    COUNT(CASE WHEN has_advanced_support = 1 THEN 1 END) AS hours_with_support,
    AVG(sfi_ratio) AS avg_sf_ratio,
    AVG(spo2_avg) AS avg_spo2
FROM sfi_data
LIMIT 5;