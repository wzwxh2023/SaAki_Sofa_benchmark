-- 步骤6：测试完整的scorecomp CTE结构（这是出错的地方）

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 24
        AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 50)
)

-- 简化的GCS数据
, gcs AS (
    SELECT co.stay_id, co.hr, 15 AS gcs_min
    FROM co
    GROUP BY co.stay_id, co.hr
)

-- 简化的脑部数据
, brain_delirium AS (
    SELECT co.stay_id, co.hr, 0 AS on_delirium_med
    FROM co
    GROUP BY co.stay_id, co.hr
)

-- 简化的ECMO数据
, ecmo_resp AS (
    SELECT co.stay_id, co.hr, 0 AS on_ecmo
    FROM co
    GROUP BY co.stay_id, co.hr
)

-- 简化的生命体征数据
, vs AS (
    SELECT co.stay_id, co.hr, 80 AS mbp_min
    FROM co
    GROUP BY co.stay_id, co.hr
)

-- 简化的血管活性药物数据
, vaso_primary AS (
    SELECT co.stay_id, co.hr, 0 AS rate_norepinephrine, 0 AS rate_epinephrine
    FROM co
    GROUP BY co.stay_id, co.hr
)

-- respiratory_data (来自步骤5，已验证工作)
, pafi AS (
    SELECT
        ie.stay_id,
        bg.charttime,
        0 AS on_advanced_support,
        bg.pao2fio2ratio
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.bg bg
        ON ie.subject_id = bg.subject_id
        AND bg.specimen = 'ART.'
    WHERE ie.stay_id IN (SELECT stay_id FROM co)
)

, sfi_data AS (
    SELECT
        co.stay_id,
        co.hr,
        220 AS sfi_ratio,
        95 AS spo2_avg,
        0 AS has_advanced_support
    FROM co
    GROUP BY co.stay_id, co.hr
)

, respiratory_data AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) AS pf_novent_min,
        MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) AS pf_vent_min,
        MIN(sfi.sfi_ratio) AS sfi_ratio,
        MIN(sfi.spo2_avg) AS spo2_avg,
        COALESCE(MAX(pafi.on_advanced_support), MAX(sfi.has_advanced_support), 0) AS has_advanced_support,
        CASE
            WHEN MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) IS NOT NULL
                 OR MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) IS NOT NULL
            THEN 'PF'
            WHEN MIN(sfi.sfi_ratio) IS NOT NULL
            THEN 'SF'
            ELSE NULL
        END AS ratio_type,
        COALESCE(
            MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END),
            MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END),
            MIN(sfi.sfi_ratio)
        ) AS oxygen_ratio
    FROM co
    LEFT JOIN pafi
        ON co.stay_id = pafi.stay_id
        AND co.starttime < pafi.charttime
        AND co.endtime >= pafi.charttime
    LEFT JOIN sfi_data sfi
        ON co.stay_id = sfi.stay_id AND co.hr = sfi.hr
    GROUP BY co.stay_id, co.hr
)

-- 关键测试：完整的scorecomp CTE结构
, scorecomp AS (
    SELECT
        co.stay_id,
        co.hadm_id,
        co.subject_id,
        co.hr,
        co.starttime,
        co.endtime,
        -- Brain/Neurological
        gcs.gcs_min,
        bd.on_delirium_med,
        -- Respiratory
        rd.pf_novent_min,
        rd.pf_vent_min,
        rd.has_advanced_support,
        rd.ratio_type,
        rd.oxygen_ratio,
        ecmo.on_ecmo,
        -- Cardiovascular
        vs.mbp_min,
        vp.rate_norepinephrine,
        vp.rate_epinephrine,
        -- Brain component
        CASE
            WHEN gcs_min BETWEEN 3 AND 5 THEN 4
            WHEN gcs_min BETWEEN 6 AND 8 THEN 3
            WHEN gcs_min BETWEEN 9 AND 10 THEN 2
            WHEN gcs_min BETWEEN 11 AND 12 THEN 1
            WHEN gcs_min = 15 AND COALESCE(on_delirium_med, 0) = 0 THEN 0
            WHEN gcs_min IS NULL AND COALESCE(on_delirium_med, 0) = 0 THEN NULL
            ELSE 0
        END AS brain,
        -- Respiratory component (FIXED VERSION)
        CASE
            WHEN on_ecmo = 1 THEN 4
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 120
                    ELSE 75
                END
                AND rd.has_advanced_support = 1 THEN 4
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 200
                    ELSE 150
                END
                AND rd.has_advanced_support = 1 THEN 3
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 250
                    ELSE 225
                END THEN 2
            WHEN rd.oxygen_ratio <= 300 THEN 1
            WHEN rd.oxygen_ratio IS NULL THEN NULL
            ELSE 0
        END AS respiratory
    FROM co
    LEFT JOIN gcs
        ON co.stay_id = gcs.stay_id AND co.hr = gcs.hr
    LEFT JOIN brain_delirium bd
        ON co.stay_id = bd.stay_id AND co.hr = bd.hr
    LEFT JOIN respiratory_data rd
        ON co.stay_id = rd.stay_id AND co.hr = rd.hr
    LEFT JOIN ecmo_resp ecmo
        ON co.stay_id = ecmo.stay_id AND co.hr = ecmo.hr
    LEFT JOIN vs
        ON co.stay_id = vs.stay_id AND co.hr = vs.hr
    LEFT JOIN vaso_primary vp
        ON co.stay_id = vp.stay_id AND co.hr = vp.hr
)

-- 测试完整结构
SELECT
    COUNT(*) AS total_records,
    COUNT(CASE WHEN brain IS NOT NULL THEN 1 END) AS brain_scores,
    COUNT(CASE WHEN respiratory IS NOT NULL THEN 1 END) AS respiratory_scores,
    AVG(brain) AS avg_brain_score,
    AVG(respiratory) AS avg_respiratory_score,
    COUNT(DISTINCT stay_id) AS unique_stays
FROM scorecomp
LIMIT 5;