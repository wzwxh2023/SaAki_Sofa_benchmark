-- =================================================================
-- SOFA-2 呼吸评分独立脚本 (修复版本)
-- 包含所有修复：CPAP/BiPAP整合、SpO2:FiO2替代逻辑、评分错误修复
-- =================================================================

-- 基础时间窗口CTE
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr >= 0
)

-- =================================================================
-- 修复1：高级呼吸支持 (包含CPAP/BiPAP)
-- =================================================================
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

    -- Add CPAP/BiPAP support from chartevents (修复：添加缺失的CPAP/BiPAP)
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

-- =================================================================
-- 修复2：血气数据 (修复stay_id问题)
-- =================================================================
, pafi AS (
    SELECT
        ie.stay_id,
        bg.charttime,
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
)

-- =================================================================
-- 修复3：SpO2:FiO2替代逻辑 (新增功能)
-- =================================================================
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

-- =================================================================
-- 综合呼吸数据 (修复4：整合PF和SF比值)
-- =================================================================
, respiratory_data AS (
    SELECT
        co.stay_id,
        co.hr,
        -- PF ratio data (from blood gases)
        MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) AS pf_novent_min,
        MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) AS pf_vent_min,
        -- SF ratio data (from SpO2 and FiO2)
        MIN(sfi.sfi_ratio) AS sfi_ratio,
        MIN(sfi.spo2_avg) AS spo2_avg,
        -- Advanced support status (combine PF and SF data)
        COALESCE(MAX(pafi.on_advanced_support), MAX(sfi.has_advanced_support), 0) AS has_advanced_support,
        -- Determine which ratio type is available for scoring
        CASE
            WHEN MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) IS NOT NULL
                 OR MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) IS NOT NULL
            THEN 'PF'
            WHEN MIN(sfi.sfi_ratio) IS NOT NULL
            THEN 'SF'
            ELSE NULL
        END AS ratio_type,
        -- Get the appropriate oxygen ratio for scoring (PF takes priority over SF)
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

-- =================================================================
-- ECMO检测
-- =================================================================
, ecmo_resp AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN ce.itemid IN (229815, 229816) AND ce.valuenum = 1 THEN 1
            ELSE 0
        END) AS on_ecmo
    FROM co
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
        AND co.starttime <= ce.charttime
        AND co.endtime >= ce.charttime
    WHERE ce.itemid IN (229815, 229816)  -- ECMO相关itemid
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- 呼吸评分计算 (修复5：修正评分逻辑错误)
-- =================================================================
, respiratory_scores AS (
    SELECT
        co.stay_id,
        co.hadm_id,
        co.subject_id,
        co.hr,
        co.starttime,
        co.endtime,
        rd.pf_novent_min,
        rd.pf_vent_min,
        rd.sfi_ratio,
        rd.spo2_avg,
        rd.has_advanced_support,
        rd.ratio_type,
        rd.oxygen_ratio,
        ecmo.on_ecmo,
        -- 修复后的呼吸评分逻辑
        CASE
            -- 4 points: ECMO (regardless of ratio)
            WHEN on_ecmo = 1 THEN 4
            -- 4 points: Ratio ≤ threshold + advanced support
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 120  -- SF ratio threshold for 4 points
                    ELSE 75  -- PF ratio threshold for 4 points
                END
                AND rd.has_advanced_support = 1 THEN 4
            -- 3 points: Ratio ≤ threshold + advanced support
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 200  -- SF ratio threshold for 3 points
                    ELSE 150  -- PF ratio threshold for 3 points
                END
                AND rd.has_advanced_support = 1 THEN 3
            -- 2 points: Ratio ≤ threshold (SF: 250, PF: 225)
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 250  -- SF ratio threshold for 2 points
                    ELSE 225  -- PF ratio threshold for 2 points
                END THEN 2
            -- 1 point: Ratio ≤ 300 (same for both SF and PF)
            WHEN rd.oxygen_ratio <= 300 THEN 1
            -- 0 points: Ratio > 300 or no data
            WHEN rd.oxygen_ratio IS NULL THEN NULL
            ELSE 0
        END AS respiratory_score
    FROM co
    LEFT JOIN respiratory_data rd
        ON co.stay_id = rd.stay_id AND co.hr = rd.hr
    LEFT JOIN ecmo_resp ecmo
        ON co.stay_id = ecmo.stay_id AND co.hr = ecmo.hr
)

-- =================================================================
-- 24小时滚动窗口评分
-- =================================================================
, respiratory_final AS (
    SELECT rs.*,
        -- Take max over last 24 hours for respiratory component
        COALESCE(MAX(respiratory_score) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING
        ), 0) AS respiratory_24hours
    FROM respiratory_scores rs
    WHERE hr >= 0
)

-- =================================================================
-- 最终输出
-- =================================================================
SELECT
    stay_id,
    hadm_id,
    subject_id,
    hr,
    starttime,
    endtime,
    ratio_type,
    oxygen_ratio,
    has_advanced_support,
    on_ecmo,
    respiratory_score,
    respiratory_24hours
FROM respiratory_final
WHERE hr >= 0
ORDER BY stay_id, hr;