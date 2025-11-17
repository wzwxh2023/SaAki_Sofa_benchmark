-- 测试呼吸相关CTE的语法
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 2 AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 10)
)
, advanced_resp_support AS (
    SELECT stay_id, starttime, endtime, ventilation_status, 1 AS has_advanced_support
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')
    UNION ALL
    SELECT ce.stay_id, ce.charttime AS starttime, ce.charttime AS endtime,
           CASE WHEN ce.itemid IN (227583) THEN 'CPAP'
                WHEN ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582) THEN 'BiPAP'
                ELSE 'Other_NIV' END AS ventilation_status, 1 AS has_advanced_support
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582, 227583)
      AND ce.valuenum IS NOT NULL AND (ce.valuenum > 0 OR ce.value IS NOT NULL)
)
, pafi AS (
    SELECT ie.stay_id, bg.charttime,
           CASE WHEN ars.stay_id IS NOT NULL THEN 1 ELSE 0 END AS on_advanced_support, bg.pao2fio2ratio
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.bg bg ON ie.subject_id = bg.subject_id AND bg.specimen = 'ART.'
    LEFT JOIN advanced_resp_support ars ON ie.stay_id = ars.stay_id
        AND bg.charttime >= ars.starttime AND bg.charttime <= ars.endtime
    WHERE ie.stay_id IN (SELECT stay_id FROM co)
)
, spo2_data AS (
    SELECT ie.stay_id, ce.charttime,
           CASE WHEN ce.valuenum IS NOT NULL AND ce.valuenum > 0 AND ce.valuenum < 100
           THEN CAST(ce.valuenum AS NUMERIC) ELSE NULL END AS spo2
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.chartevents ce ON ie.stay_id = ce.stay_id
    WHERE ce.itemid = 220227 AND ce.valuenum IS NOT NULL
      AND ce.valuenum > 0 AND ce.valuenum < 100
      AND ie.stay_id IN (SELECT stay_id FROM co)
)
, fio2_chart_data AS (
    SELECT ie.stay_id, ce.charttime,
           CASE WHEN ce.valueuom = '%' AND ce.valuenum IS NOT NULL
           THEN CAST(ce.valuenum AS NUMERIC) / 100
           WHEN ce.valuenum IS NOT NULL AND ce.valuenum <= 1
           THEN CAST(ce.valuenum AS NUMERIC)
           WHEN ce.valuenum IS NOT NULL AND ce.valuenum > 1
           THEN CAST(ce.valuenum AS NUMERIC) / 100 ELSE NULL END AS fio2
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.chartevents ce ON ie.stay_id = ce.stay_id
    WHERE ce.itemid IN (229841, 229280, 230086) AND ce.valuenum IS NOT NULL
      AND ce.valuenum > 0 AND ce.valuenum <= 100
      AND ie.stay_id IN (SELECT stay_id FROM co)
)
, sfi_data AS (
    SELECT co.stay_id, co.hr,
           AVG(spo2.spo2) AS spo2_avg, AVG(fio2.fio2) AS fio2_avg,
           CASE WHEN AVG(spo2.spo2) < 98 AND AVG(fio2.fio2) > 0 AND AVG(fio2.fio2) <= 1
           THEN AVG(spo2.spo2) / AVG(fio2.fio2) ELSE NULL END AS sfi_ratio,
           MAX(ars.has_advanced_support) AS has_advanced_support
    FROM co
    LEFT JOIN spo2_data spo2 ON co.stay_id = spo2.stay_id
        AND co.starttime <= spo2.charttime AND co.endtime >= spo2.charttime
    LEFT JOIN fio2_chart_data fio2 ON co.stay_id = fio2.stay_id
        AND co.starttime <= fio2.charttime AND co.endtime >= fio2.charttime
    LEFT JOIN advanced_resp_support ars ON co.stay_id = ars.stay_id
        AND co.starttime <= ars.starttime AND co.endtime >= ars.endtime
    GROUP BY co.stay_id, co.hr
)
, respiratory_data AS (
    SELECT co.stay_id, co.hr,
           MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) AS pf_novent_min,
           MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) AS pf_vent_min,
           MIN(sfi.sfi_ratio) AS sfi_ratio, MIN(sfi.spo2_avg) AS spo2_avg,
           COALESCE(MAX(pafi.on_advanced_support), MAX(sfi.has_advanced_support), 0) AS has_advanced_support,
           CASE WHEN MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) IS NOT NULL
                 OR MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) IS NOT NULL
                THEN 'PF' WHEN MIN(sfi.sfi_ratio) IS NOT NULL THEN 'SF' ELSE NULL END AS ratio_type,
           COALESCE(MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END),
                    MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END),
                    MIN(sfi.sfi_ratio)) AS oxygen_ratio
    FROM co
    LEFT JOIN pafi ON co.stay_id = pafi.stay_id
        AND co.starttime < pafi.charttime AND co.endtime >= pafi.charttime
    LEFT JOIN sfi_data sfi ON co.stay_id = sfi.stay_id AND co.hr = sfi.hr
    GROUP BY co.stay_id, co.hr
)
, ecmo_resp AS (
    SELECT co.stay_id, co.hr, 0 AS on_ecmo
    FROM co
    GROUP BY co.stay_id, co.hr
)
, scorecomp AS (
    SELECT co.stay_id, co.hr, co.starttime, co.endtime,
           rd.pf_novent_min, rd.pf_vent_min, rd.has_advanced_support, rd.ratio_type, rd.oxygen_ratio,
           ecmo.on_ecmo,
           CASE WHEN ecmo.on_ecmo = 1 THEN 4
                WHEN rd.oxygen_ratio <= CASE WHEN rd.ratio_type = 'SF' THEN 120 ELSE 75 END
                     AND rd.has_advanced_support = 1 THEN 4
                WHEN rd.oxygen_ratio <= CASE WHEN rd.ratio_type = 'SF' THEN 200 ELSE 150 END
                     AND rd.has_advanced_support = 1 THEN 3
                WHEN rd.oxygen_ratio <= CASE WHEN rd.ratio_type = 'SF' THEN 250 ELSE 225 END THEN 2
                WHEN rd.oxygen_ratio <= 300 THEN 1
                WHEN rd.oxygen_ratio IS NULL THEN NULL ELSE 0 END AS respiratory
    FROM co
    LEFT JOIN respiratory_data rd ON co.stay_id = rd.stay_id AND co.hr = rd.hr
    LEFT JOIN ecmo_resp ecmo ON co.stay_id = ecmo.stay_id AND co.hr = ecmo.hr
)
SELECT stay_id, hr, ratio_type, oxygen_ratio, has_advanced_support, respiratory
FROM scorecomp
ORDER BY stay_id, hr LIMIT 10;