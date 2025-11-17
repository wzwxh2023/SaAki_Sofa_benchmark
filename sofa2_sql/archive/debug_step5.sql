-- 步骤5：测试完整的呼吸评分逻辑（这是我们怀疑有问题的地方）

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

-- 简化的血气数据
, pafi AS (
    SELECT
        ie.stay_id,
        bg.charttime,
        CASE
            WHEN 1 = 0 THEN 1  -- 简化版本，暂时不检查高级支持
            ELSE 0
        END AS on_advanced_support,
        bg.pao2fio2ratio
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.bg bg
        ON ie.subject_id = bg.subject_id
        AND bg.specimen = 'ART.'
    WHERE ie.stay_id IN (SELECT stay_id FROM co)
)

-- 简化的SF数据
, sfi_data AS (
    SELECT
        co.stay_id,
        co.hr,
        220 AS sfi_ratio,  -- 模拟数据
        95 AS spo2_avg,
        0 AS has_advanced_support
    FROM co
    GROUP BY co.stay_id, co.hr
)

-- 关键测试：respiratory_data CTE
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

-- 测试呼吸评分计算
SELECT
    rd.stay_id,
    rd.hr,
    rd.ratio_type,
    rd.oxygen_ratio,
    rd.has_advanced_support,
    -- 呼吸评分逻辑
    CASE
        WHEN rd.oxygen_ratio IS NULL THEN NULL
        WHEN rd.oxygen_ratio <= 75 AND rd.has_advanced_support = 1 THEN 4
        WHEN rd.oxygen_ratio <= 150 AND rd.has_advanced_support = 1 THEN 3
        WHEN rd.oxygen_ratio <= 225 THEN 2
        WHEN rd.oxygen_ratio <= 300 THEN 1
        ELSE 0
    END AS respiratory_score
FROM respiratory_data rd
ORDER BY rd.stay_id, rd.hr
LIMIT 10;