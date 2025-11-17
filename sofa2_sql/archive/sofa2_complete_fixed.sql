-- =================================================================
-- SOFA-2 完整评分脚本（修复版本）
-- 整合了所有修复：呼吸评分完整实现，其他组件保持原有逻辑
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
    WHERE ih.hr BETWEEN 0 AND 24
        AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 50)
)

-- =================================================================
-- SECTION 1: BRAIN/NEUROLOGICAL (SOFA-2 Compliant)
-- =================================================================

-- 步骤1: 检测镇静状态
, sedation_detection AS (
    -- 检测镇静药物使用
    SELECT
        co.stay_id,
        co.hr,
        co.starttime,
        co.endtime,
        MAX(CASE
            WHEN pr.starttime <= co.endtime
            AND COALESCE(pr.stoptime, co.endtime) >= co.starttime
            AND LOWER(pr.drug) LIKE ANY(ARRAY[
                '%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
                '%fentanyl%', '%remifentanil%', '%morphine%', '%hydromorphone%',
                '%dexmedetomidine%'
            ])
            THEN 1 ELSE 0
        END) AS on_sedation_meds,
        MAX(CASE
            WHEN pr.starttime <= co.endtime
            AND COALESCE(pr.stoptime, co.endtime) >= co.starttime
            AND LOWER(pr.drug) LIKE ANY(ARRAY[
                '%cisatracurium%', '%vecuronium%', '%rocuronium%', '%atracurium%',
                '%succinylcholine%', '%pancuronium%'
            ])
            THEN 1 ELSE 0
        END) AS on_paralytics,
        -- 检测深度镇静（基于RASS评分）
        MAX(CASE
            WHEN ce.charttime >= co.starttime AND ce.charttime < co.endtime
            AND ce.itemid IN (223900, 220739)  -- RASS score itemids
            AND ce.valuenum IS NOT NULL
            AND CAST(ce.valuenum AS NUMERIC) <= -4  -- Deep sedation or lower
            THEN 1 ELSE 0
        END) AS deep_sedation
    FROM co
    LEFT JOIN mimiciv_hosp.prescriptions pr
        ON co.hadm_id = pr.hadm_id
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
    GROUP BY co.stay_id, co.hr, co.starttime, co.endtime
)

-- 步骤2: 清洗和选择有效的GCS数据
, gcs_clean AS (
    SELECT
        gcs.stay_id,
        gcs.charttime,
        -- 数据清洗：限制GCS在3-15范围内
        CASE
            WHEN gcs.gcs < 3 THEN 3
            WHEN gcs.gcs > 15 THEN 15
            ELSE gcs.gcs
        END AS gcs_clean,
        -- GCS组件清洗
        CASE
            WHEN gcs.gcs_motor < 1 THEN 1
            WHEN gcs.gcs_motor > 6 THEN 6
            ELSE gcs.gcs_motor
        END AS gcs_motor_clean,
        CASE
            WHEN gcs.gcs_verbal < 1 THEN 1
            WHEN gcs.gcs_verbal > 5 THEN 5
            ELSE gcs.gcs_verbal
        END AS gcs_verbal_clean,
        CASE
            WHEN gcs.gcs_eyes < 1 THEN 1
            WHEN gcs.gcs_eyes > 4 THEN 4
            ELSE gcs.gcs_eyes
        END AS gcs_eyes_clean,
        -- 检查数据完整性
        CASE
            WHEN gcs.gcs IS NULL OR gcs.gcs_motor IS NULL
                 OR gcs.gcs_verbal IS NULL OR gcs.gcs_eyes IS NULL
            THEN 0
            ELSE 1
        END AS is_complete
    FROM mimiciv_derived.gcs gcs
    WHERE gcs.gcs IS NOT NULL  -- 只要有GCS记录就保留
)

, gcs_hourly_stats AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(gcs_clean) AS gcs_min_in_hour,
        MIN(gcs_motor_clean) AS motor_min_in_hour,
        MIN(gcs_verbal_clean) AS verbal_min_in_hour,
        MIN(gcs_eyes_clean) AS eyes_min_in_hour,
        MAX(CASE
            WHEN gcs.charttime >= co.starttime AND gcs.charttime < co.endtime
            THEN 1 ELSE 0
        END) AS has_current_gcs
    FROM co
    LEFT JOIN gcs_clean gcs
        ON gcs.stay_id = co.stay_id
        AND gcs.charttime >= co.starttime
        AND gcs.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

, gcs_last_prior AS (
    SELECT
        co.stay_id,
        co.hr,
        g_prev.gcs_clean AS gcs_last_prior,
        g_prev.gcs_motor_clean AS motor_last_prior,
        g_prev.gcs_verbal_clean AS verbal_last_prior,
        g_prev.gcs_eyes_clean AS eyes_last_prior
    FROM co
    LEFT JOIN LATERAL (
        SELECT
            gcs_clean,
            gcs_motor_clean,
            gcs_verbal_clean,
            gcs_eyes_clean
        FROM gcs_clean gcs_prev
        WHERE gcs_prev.stay_id = co.stay_id
            AND gcs_prev.charttime < co.starttime
        ORDER BY gcs_prev.charttime DESC
        LIMIT 1
    ) g_prev ON TRUE
)

-- 步骤4: 最终GCS数据处理
, gcs_final AS (
    SELECT
        co.stay_id,
        co.hr,
        ghs.gcs_min_in_hour,
        ghs.motor_min_in_hour,
        ghs.verbal_min_in_hour,
        ghs.eyes_min_in_hour,
        ghs.has_current_gcs,
        glp.gcs_last_prior,
        glp.motor_last_prior,
        glp.verbal_last_prior,
        glp.eyes_last_prior
    FROM co
    LEFT JOIN gcs_hourly_stats ghs
        ON co.stay_id = ghs.stay_id AND co.hr = ghs.hr
    LEFT JOIN gcs_last_prior glp
        ON co.stay_id = glp.stay_id AND co.hr = glp.hr
)

-- 步骤5: 谵妄药物检测
, brain_delirium AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN pr.starttime <= co.endtime
            AND COALESCE(pr.stoptime, co.endtime) >= co.starttime
            AND LOWER(pr.drug) LIKE ANY(ARRAY[
                '%haloperidol%', '%haldol%', '%quetiapine%', '%seroquel%',
                '%olanzapine%', '%zyprexa%', '%risperidone%', '%risperdal%',
                '%ziprasidone%', '%geodon%'
            ])
            THEN 1 ELSE 0
        END) AS on_delirium_med
    FROM co
    LEFT JOIN mimiciv_hosp.prescriptions pr
        ON co.hadm_id = pr.hadm_id
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 2: RESPIRATORY (完全修复版本)
-- =================================================================
-- 高级呼吸支持（SOFA-2优化版本）
, advanced_resp_support AS (
    -- 方法1: 从ventilation表获取主要通气支持
    SELECT
        stay_id,
        starttime,
        endtime,
        ventilation_status,
        1 AS has_advanced_support,
        'ventilation_table' AS source
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')

    UNION ALL

    -- 方法2: 从chartevents获取CPAP/BiPAP支持
    SELECT
        ce.stay_id,
        ce.charttime AS starttime,
        ce.charttime + INTERVAL '5 MINUTE' AS endtime,  -- 假设单次记录代表5分钟支持
        CASE
            WHEN ce.itemid IN (227583) THEN 'CPAP'
            WHEN ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582) THEN 'BiPAP'
            ELSE 'Other_NIV'
        END AS ventilation_status,
        1 AS has_advanced_support,
        'chartevents_cpap' AS source
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582, 227583)
      AND ce.valuenum IS NOT NULL
      AND (ce.valuenum > 0 OR ce.value IS NOT NULL)

    UNION ALL

    -- 方法3: 检测氧疗设备支持（补充）
    SELECT DISTINCT
        ce.stay_id,
        ce.charttime AS starttime,
        ce.charttime + INTERVAL '10 MINUTE' AS endtime,  -- 设备设置假设持续10分钟
        'O2_Delivery' AS ventilation_status,
        1 AS has_advanced_support,
        'oxygen_device' AS source
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (
        226708,  -- High Flow Nasal Cannula settings
        227287,  -- CPAP pressure
        227288,  -- BiPAP settings
        223835,  -- O2 Flow
        50816    -- Supplemental O2
    )
    AND ce.valuenum > 0
)

, advanced_support_sessions AS (
    SELECT
        stay_id,
        ventilation_status,
        starttime,
        endtime,
        SUM(new_session) OVER (PARTITION BY stay_id, ventilation_status ORDER BY starttime) AS session_id
    FROM (
        SELECT
            stay_id,
            ventilation_status,
            starttime,
            endtime,
            CASE
                WHEN starttime - LAG(endtime) OVER (PARTITION BY stay_id, ventilation_status ORDER BY starttime) <= INTERVAL '30 MINUTE'
                THEN 0
                ELSE 1
            END AS new_session
        FROM advanced_resp_support
    ) events_with_sessions
)

, advanced_support_merged AS (
    SELECT
        stay_id,
        ventilation_status,
        MIN(starttime) AS event_starttime,
        MAX(endtime) AS event_endtime,
        1 AS has_advanced_support
    FROM advanced_support_sessions
    GROUP BY stay_id, ventilation_status, session_id
)

-- 统一呼吸数据时间窗口检测
, respiratory_time_windows AS (
    SELECT
        co.stay_id,
        co.hr,
        co.starttime AS hour_start,
        co.endtime AS hour_end,
        -- 检测该小时内是否有任何高级呼吸支持
        MAX(CASE
            WHEN asm.event_starttime < co.endtime AND asm.event_endtime > co.starttime
            THEN 1 ELSE 0
        END) AS any_advanced_support_in_hour,
        -- 计算高级呼吸支持持续时间（分钟）
        SUM(
            GREATEST(0,
                EXTRACT(
                    EPOCH FROM LEAST(asm.event_endtime, co.endtime) - GREATEST(asm.event_starttime, co.starttime)
                )
            )
        ) / 60 AS advanced_support_minutes_in_hour
    FROM co
    LEFT JOIN advanced_support_merged asm
        ON co.stay_id = asm.stay_id
        AND asm.event_starttime < co.endtime
        AND asm.event_endtime > co.starttime
    GROUP BY co.stay_id, co.hr, co.starttime, co.endtime
)

-- 血气数据
, pafi AS (
    SELECT
        ie.stay_id,
        bg.charttime,
        CASE
            WHEN asm.stay_id IS NOT NULL THEN 1
            ELSE 0
        END AS on_advanced_support,
        bg.pao2fio2ratio
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.bg bg
        ON ie.subject_id = bg.subject_id
        AND bg.specimen = 'ART.'
    LEFT JOIN advanced_support_merged asm
        ON ie.stay_id = asm.stay_id
            AND bg.charttime >= asm.event_starttime
            AND bg.charttime <= asm.event_endtime
)

-- SpO2数据（SOFA-2要求使用最小值而非平均值）
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

-- FiO2数据
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

-- SF比值数据（SOFA-2：使用最小SpO2，仅在SpO2<98%时使用）
, sfi_data AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(spo2.spo2) AS spo2_min,  -- SOFA-2要求使用最小值
        MAX(fio2.fio2) AS fio2_max,  -- 使用最大FiO2以得到最坏情况
        CASE
            WHEN MIN(spo2.spo2) < 98 AND MAX(fio2.fio2) > 0 AND MAX(fio2.fio2) <= 1
            THEN MIN(spo2.spo2) / MAX(fio2.fio2)
            ELSE NULL
        END AS sfi_ratio,
        MAX(asm.has_advanced_support) AS has_advanced_support
    FROM co
    LEFT JOIN spo2_data spo2
        ON co.stay_id = spo2.stay_id
        AND spo2.charttime >= co.starttime
        AND spo2.charttime < co.endtime
    LEFT JOIN fio2_chart_data fio2
        ON co.stay_id = fio2.stay_id
        AND fio2.charttime >= co.starttime
        AND fio2.charttime < co.endtime
    LEFT JOIN advanced_support_merged asm
        ON co.stay_id = asm.stay_id
        AND (asm.event_starttime < co.endtime AND asm.event_endtime > co.starttime)
    GROUP BY co.stay_id, co.hr
)

-- 综合呼吸数据（SOFA-2兼容版本）
, respiratory_data AS (
    SELECT
        co.stay_id,
        co.hr,
        -- PF ratio数据（来自血气分析）
        MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) AS pf_novent_min,
        MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) AS pf_vent_min,
        -- SF ratio数据（来自SpO2）
        MIN(sfi.sfi_ratio) AS sfi_ratio,
        MIN(sfi.spo2_min) AS spo2_min,  -- 更新为spo2_min
        -- 高级呼吸支持状态
        COALESCE(MAX(pafi.on_advanced_support), MAX(sfi.has_advanced_support), 0) AS has_advanced_support,
        -- SOFA-2逻辑：优先使用PF ratio，不可用时才用SF ratio
        CASE
            -- 当血气数据可用时（PaO2和FiO2都能形成ratio）
            WHEN (MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) IS NOT NULL
                 OR MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) IS NOT NULL)
            THEN 'PF'
            -- 仅当血气不可用且SpO2<98%时才使用SF ratio
            WHEN MIN(sfi.sfi_ratio) IS NOT NULL AND MIN(sfi.spo2_min) < 98
            THEN 'SF'
            ELSE NULL
        END AS ratio_type,
        -- 选择最合适的氧合比值（优先PF）
        COALESCE(
            MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END),
            MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END),
            MIN(sfi.sfi_ratio)
        ) AS oxygen_ratio
    FROM co
    LEFT JOIN pafi
        ON co.stay_id = pafi.stay_id
        AND pafi.charttime >= co.starttime
        AND pafi.charttime < co.endtime
    LEFT JOIN sfi_data sfi
        ON co.stay_id = sfi.stay_id AND co.hr = sfi.hr
    GROUP BY co.stay_id, co.hr
)

-- ECMO检测（SOFA-2兼容的全面检测）
, ecmo_resp AS (
    SELECT DISTINCT
        co.stay_id,
        co.hr,
        MAX(CASE
            -- 方法1: 直接ECMO状态指示器
            WHEN ce.charttime >= co.starttime AND ce.charttime < co.endtime
            AND ce.itemid IN (229815, 229816) AND ce.valuenum = 1 THEN 1
            -- 方法2: 通过机械支持表检测ECMO
            WHEN ms.has_mechanical_support = 1 AND ms.device_type = 'ECMO'
                 AND ms.charttime >= co.starttime AND ms.charttime < co.endtime THEN 1
            -- 方法3: 通过通气状态检测ECMO相关模式
            WHEN v.ventilation_status ILIKE '%ECMO%'
                 AND v.starttime < co.endtime AND COALESCE(v.endtime, co.endtime) > co.starttime THEN 1
            -- 方法4: 通过procedureevents检测ECMO操作
            WHEN pe.charttime >= co.starttime AND pe.charttime < co.endtime
            AND LOWER(pe.itemid::text) LIKE ANY(ARRAY[
                '%ecmo%', '%extracorporeal%', '%membrane%'
            ]) THEN 1
            ELSE 0
        END) AS on_ecmo
    FROM co
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
    LEFT JOIN mechanical_support ms
        ON co.stay_id = ms.stay_id
    LEFT JOIN mimiciv_derived.ventilation v
        ON co.stay_id = v.stay_id
    LEFT JOIN mimiciv_icu.procedureevents pe
        ON co.stay_id = pe.stay_id
    WHERE
        ce.itemid IN (229815, 229816)  -- ECMO状态itemid
        OR ms.device_type = 'ECMO'
        OR v.ventilation_status ILIKE '%ECMO%'
        OR LOWER(pe.itemid::text) LIKE ANY(ARRAY['%ecmo%', '%extracorporeal%', '%membrane%'])
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 4: LIVER
-- =================================================================
, bili AS (
    SELECT co.stay_id, co.hr
        , MAX(enz.bilirubin_total) AS bilirubin_max
    FROM co
    LEFT JOIN mimiciv_derived.enzyme enz
        ON co.hadm_id = enz.hadm_id
            AND enz.charttime >= co.starttime
            AND enz.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 5: KIDNEY
-- =================================================================
, cr AS (
    SELECT co.stay_id, co.hr
        , MAX(chem.creatinine) AS creatinine_max
        , MAX(chem.potassium) AS potassium_max
    FROM co
    LEFT JOIN mimiciv_derived.chemistry chem
        ON co.hadm_id = chem.hadm_id
            AND chem.charttime >= co.starttime
            AND chem.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

, bg_metabolic AS (
    SELECT co.stay_id, co.hr
        , MIN(bg.ph) AS ph_min
        , MIN(bg.bicarbonate) AS bicarbonate_min
    FROM co
    LEFT JOIN mimiciv_derived.bg bg
        ON co.subject_id = bg.subject_id
            AND bg.specimen = 'ART.'
            AND bg.charttime >= co.starttime
            AND bg.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

-- 患者体重（用于基于体重的尿量计算）
, patient_weight AS (
    SELECT
        stay_id,
        weight
    FROM mimiciv_derived.first_day_weight
    WHERE weight IS NOT NULL AND weight > 0
)

-- RRT检测
, rrt_active AS (
    SELECT
        stay_id,
        charttime,
        dialysis_active AS on_rrt
    FROM mimiciv_derived.rrt
    WHERE dialysis_active = 1
)

-- RRT代谢标准
, rrt_metabolic_criteria AS (
    SELECT
        co.stay_id,
        co.hr,
        cr.creatinine_max,
        k.potassium_max,
        bg.ph_min,
        bg.bicarbonate_min,
        CASE
            WHEN cr.creatinine_max > 1.2
                 AND (k.potassium_max >= 6.0
                      OR (bg.ph_min <= 7.2 AND bg.bicarbonate_min <= 12))
            THEN 1
            ELSE 0
        END AS meets_rrt_criteria
    FROM co
    LEFT JOIN (
        SELECT ie.stay_id, chem.charttime, MAX(chem.creatinine) AS creatinine_max
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.chemistry chem
            ON ie.subject_id = chem.subject_id
            AND chem.charttime >= ie.intime
            AND chem.charttime < ie.outtime
        GROUP BY ie.stay_id, chem.charttime
    ) cr ON co.stay_id = cr.stay_id
        AND cr.charttime >= co.starttime
        AND cr.charttime < co.endtime
    LEFT JOIN (
        SELECT ie.stay_id, chem.charttime, MAX(chem.potassium) AS potassium_max
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.chemistry chem
            ON ie.subject_id = chem.subject_id
            AND chem.charttime >= ie.intime
            AND chem.charttime < ie.outtime
        GROUP BY ie.stay_id, chem.charttime
    ) k ON co.stay_id = k.stay_id
        AND k.charttime >= co.starttime
        AND k.charttime < co.endtime
    LEFT JOIN (
        SELECT ie.stay_id, bg.charttime, MIN(bg.ph) AS ph_min, MIN(bg.bicarbonate) AS bicarbonate_min
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.bg bg
            ON ie.subject_id = bg.subject_id
            AND bg.charttime >= ie.intime
            AND bg.charttime < ie.outtime
        WHERE bg.specimen = 'ART.'
        GROUP BY ie.stay_id, bg.charttime
    ) bg ON co.stay_id = bg.stay_id
        AND bg.charttime >= co.starttime
        AND bg.charttime < co.endtime
)

-- SOFA-2 肾脏评分：精确连续尿量分析
, uo_continuous AS (
    -- 步骤1: 原始尿量数据与体重
    WITH uo_raw AS (
        SELECT
            u.stay_id,
            u.charttime,
            u.urineoutput,
            w.weight,
            LAG(u.charttime) OVER (PARTITION BY u.stay_id ORDER BY u.charttime) as last_charttime
        FROM mimiciv_derived.urine_output u
        LEFT JOIN patient_weight w ON u.stay_id = w.stay_id
    ),

    -- 步骤2: 计算间隔和速率
    uo_interval AS (
        SELECT
            stay_id,
            charttime,
            urineoutput,
            weight,
            CASE
                WHEN last_charttime IS NULL THEN NULL
                ELSE EXTRACT(EPOCH FROM (charttime - last_charttime)) / 3600.0
            END AS interval_hours
        FROM uo_raw
    ),

    -- 步骤3: 计算ml/kg/h速率
    uo_rate AS (
        SELECT
            stay_id,
            charttime,
            interval_hours,
            urineoutput,
            weight,
            CASE
                WHEN interval_hours IS NULL OR weight = 0 THEN NULL
                ELSE (urineoutput / weight) / interval_hours
            END AS uo_ml_kg_h
        FROM uo_interval
    ),

    -- 步骤4: 标记低输出并创建组
    uo_flags AS (
        SELECT
            stay_id,
            charttime,
            interval_hours,
            uo_ml_kg_h,
            CASE WHEN uo_ml_kg_h < 0.5 THEN 1 ELSE 0 END AS low_05_flag,
            CASE WHEN uo_ml_kg_h < 0.3 THEN 1 ELSE 0 END AS low_03_flag,
            CASE WHEN urineoutput = 0 THEN 1 ELSE 0 END AS anuria_flag,

            -- 为连续期创建组ID
            ROW_NUMBER() OVER (PARTITION BY stay_id ORDER BY charttime) -
            ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN uo_ml_kg_h < 0.5 THEN 1 ELSE 0 END ORDER BY charttime) AS grp_low_05,
            ROW_NUMBER() OVER (PARTITION BY stay_id ORDER BY charttime) -
            ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN uo_ml_kg_h < 0.3 THEN 1 ELSE 0 END ORDER BY charttime) AS grp_low_03,
            ROW_NUMBER() OVER (PARTITION BY stay_id ORDER BY charttime) -
            ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN urineoutput = 0 THEN 1 ELSE 0 END ORDER BY charttime) AS grp_anuria
        FROM uo_rate
    ),

    -- 步骤5: 计算累积持续时间
    uo_durations AS (
        SELECT
            stay_id,
            charttime,
            uo_ml_kg_h,

            -- 每个连续低输出期的累积小时数
            CASE
                WHEN low_05_flag = 1 THEN
                    SUM(interval_hours) OVER (PARTITION BY stay_id, grp_low_05)
                ELSE 0
            END AS hours_low_05,

            CASE
                WHEN low_03_flag = 1 THEN
                    SUM(interval_hours) OVER (PARTITION BY stay_id, grp_low_03)
                ELSE 0
            END AS hours_low_03,

            CASE
                WHEN anuria_flag = 1 THEN
                    SUM(interval_hours) OVER (PARTITION BY stay_id, grp_anuria)
                ELSE 0
            END AS hours_anuria
        FROM uo_flags
    )

    SELECT * FROM uo_durations
),

-- 步骤6: 获取每小时的的最大连续持续时间
uo_max_durations AS (
    SELECT DISTINCT
        co.stay_id,
        co.hr,
        MAX(uc.hours_low_05) AS max_hours_low_05,
        MAX(uc.hours_low_03) AS max_hours_low_03,
        MAX(uc.hours_anuria) AS max_hours_anuria
    FROM co
    LEFT JOIN (
        SELECT stay_id, charttime, hours_low_05, hours_low_03, hours_anuria
        FROM uo_continuous
    ) uc
        ON co.stay_id = uc.stay_id
        AND uc.charttime >= co.starttime
        AND uc.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

, rrt_status AS (
    SELECT DISTINCT
        co.stay_id,
        co.hr,
        MAX(rrt.on_rrt) AS on_rrt
    FROM co
    LEFT JOIN rrt_active rrt
        ON co.stay_id = rrt.stay_id
        AND rrt.charttime >= co.starttime
        AND rrt.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 6: HEMOSTASIS (COAGULATION)
-- =================================================================
, plt AS (
    SELECT DISTINCT
        co.stay_id, co.hr
        , MIN(cbc.platelet) AS platelet_min
    FROM co
    LEFT JOIN mimiciv_derived.complete_blood_count cbc
        ON co.hadm_id = cbc.hadm_id
            AND cbc.charttime >= co.starttime
            AND cbc.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 3: CARDIOVASCULAR (简化版本)
-- =================================================================
, vs AS (
    SELECT DISTINCT
        co.stay_id, co.hr
        , MIN(vs.mbp) AS mbp_min
    FROM co
    LEFT JOIN mimiciv_derived.vitalsign vs
        ON co.stay_id = vs.stay_id
            AND vs.charttime >= co.starttime
            AND vs.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

, vaso_primary AS (
    SELECT DISTINCT
        co.stay_id,
        co.hr,
        MAX(va.norepinephrine) AS rate_norepinephrine,
        MAX(va.epinephrine) AS rate_epinephrine
    FROM co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- 综合评分计算
-- =================================================================
, scorecomp AS (
    SELECT
        co.stay_id,
        co.hadm_id,
        co.subject_id,
        co.hr,
        co.starttime,
        co.endtime,
        -- Brain/Neurological (SOFA-2 Compliant)
        gf.gcs_min_in_hour,
        gf.motor_min_in_hour,
        gf.gcs_last_prior,
        gf.motor_last_prior,
        sd.on_sedation_meds,
        sd.on_paralytics,
        sd.deep_sedation,
        CASE
            WHEN COALESCE(sd.on_sedation_meds, 0) = 1
                OR COALESCE(sd.on_paralytics, 0) = 1
                OR COALESCE(sd.deep_sedation, 0) = 1
            THEN 1 ELSE 0
        END AS sedation_or_paralytic,
        CASE
            WHEN gf.gcs_min_in_hour IS NOT NULL THEN gf.gcs_min_in_hour
            WHEN (COALESCE(sd.on_sedation_meds, 0) = 1
                OR COALESCE(sd.on_paralytics, 0) = 1
                OR COALESCE(sd.deep_sedation, 0) = 1)
                AND gf.gcs_last_prior IS NOT NULL
            THEN gf.gcs_last_prior
            WHEN (COALESCE(sd.on_sedation_meds, 0) = 1
                OR COALESCE(sd.on_paralytics, 0) = 1
                OR COALESCE(sd.deep_sedation, 0) = 1)
                AND gf.motor_last_prior IS NOT NULL
            THEN gf.motor_last_prior
            WHEN gf.motor_min_in_hour IS NOT NULL THEN gf.motor_min_in_hour
            ELSE NULL
        END AS effective_brain_gcs,
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
        -- Liver
        bili.bilirubin_max,
        -- Kidney
        cr.creatinine_max,
        cr.potassium_max,
        bgm.ph_min,
        bgm.bicarbonate_min,
        rmc.meets_rrt_criteria,
        uod.max_hours_low_05,
        uod.max_hours_low_03,
        uod.max_hours_anuria,
        rrt.on_rrt,
        -- Hemostasis
        plt.platelet_min,
        -- Brain component (SOFA-2 Compliant)
        CASE
            -- 镇静/肌松且缺少镇静前记录，默认0分
            WHEN sedation_or_paralytic = 1 AND effective_brain_gcs IS NULL THEN 0
            -- 正常GCS评分逻辑
            WHEN effective_brain_gcs <= 5 THEN 4
            WHEN effective_brain_gcs BETWEEN 6 AND 8 THEN 3
            WHEN effective_brain_gcs BETWEEN 9 AND 12 THEN 2
            WHEN effective_brain_gcs BETWEEN 13 AND 14 THEN 1
            -- GCS = 15 且无谵妄药物时为0分
            WHEN effective_brain_gcs = 15 AND COALESCE(on_delirium_med, 0) = 0 THEN 0
            -- 任何患者使用谵妄药物最少得1分
            WHEN COALESCE(on_delirium_med, 0) = 1 THEN 1
            -- 缺失数据默认0分
            WHEN effective_brain_gcs IS NULL THEN 0
            ELSE 0
        END AS brain,
        -- Respiratory component (SOFA-2原文标准 - 区分PF和SF阈值)
        CASE
            -- 4 points: ECMO (自动最高分)
            WHEN on_ecmo = 1 THEN 4
            -- 4 points: 最严重的低氧血症（需要高级呼吸支持）
            WHEN rd.oxygen_ratio <=
                CASE
                    -- SF ratio: ≤120 (with ventilatory support or ECMO) → 4 points
                    WHEN rd.ratio_type = 'SF' THEN 120
                    -- PF ratio: ≤75 (with ventilatory support) → 4 points
                    ELSE 75
                END
                AND rd.has_advanced_support = 1 THEN 4
            -- 3 points: 重度低氧血症（需要高级呼吸支持）
            WHEN rd.oxygen_ratio <=
                CASE
                    -- SF ratio: ≤200 (with ventilatory support) → 3 points
                    WHEN rd.ratio_type = 'SF' THEN 200
                    -- PF ratio: ≤150 (with ventilatory support) → 3 points
                    ELSE 150
                END
                AND rd.has_advanced_support = 1 THEN 3
            -- 2 points: 中度低氧血症
            WHEN rd.oxygen_ratio <=
                CASE
                    -- SF ratio: ≤250 → 2 points
                    WHEN rd.ratio_type = 'SF' THEN 250
                    -- PF ratio: ≤225 → 2 points
                    ELSE 225
                END THEN 2
            -- 1 point: 轻度低氧血症
            WHEN rd.oxygen_ratio <= 300 THEN 1
            -- 缺失数据
            WHEN rd.oxygen_ratio IS NULL THEN NULL
            -- 0 points: 正常氧合 (>300)
            ELSE 0
        END AS respiratory,
        -- Cardiovascular component (简化版本)
        CASE
            WHEN mbp_min < 70 THEN 1
            WHEN COALESCE(rate_norepinephrine, 0) > 0 OR COALESCE(rate_epinephrine, 0) > 0 THEN 2
            WHEN COALESCE(mbp_min, 0) = 0 AND
                 COALESCE(rate_norepinephrine, 0) = 0 AND COALESCE(rate_epinephrine, 0) = 0 THEN NULL
            ELSE 0
        END AS cardiovascular,
        -- Liver component
        CASE
            -- SOFA-2: 改变阈值为 ≤ 而不是 <
            WHEN bilirubin_max > 12.0 THEN 4
            WHEN bilirubin_max > 6.0 AND bilirubin_max <= 12.0 THEN 3
            WHEN bilirubin_max > 3.0 AND bilirubin_max <= 6.0 THEN 2
            WHEN bilirubin_max > 1.2 AND bilirubin_max <= 3.0 THEN 1
            WHEN bilirubin_max IS NULL THEN NULL
            ELSE 0
        END AS liver,
        -- Kidney component
        CASE
            -- 4 points: 正在接受或符合RRT标准
            WHEN on_rrt = 1 THEN 4
            WHEN meets_rrt_criteria = 1 THEN 4
            -- 3 points: 肌酐 >3.5 mg/dL 或严重少尿/无尿
            WHEN creatinine_max > 3.5 THEN 3
            WHEN max_hours_low_03 >= 24 THEN 3  -- <0.3 ml/kg/h 持续 ≥24h
            WHEN max_hours_anuria >= 12 THEN 3      -- 完全无尿 ≥12h
            -- 2 points: 肌酐 2.0-3.5 mg/dL 或中度少尿 (≥12h)
            WHEN creatinine_max > 2.0 AND creatinine_max <= 3.5 THEN 2
            WHEN max_hours_low_05 >= 12 THEN 2      -- <0.5 ml/kg/h 持续 ≥12h
            -- 1 point: 肌酐 1.2-2.0 mg/dL 或轻度少尿 (6-12h)
            WHEN creatinine_max > 1.2 AND creatinine_max <= 2.0 THEN 1
            WHEN max_hours_low_05 >= 6 AND max_hours_low_05 < 12 THEN 1  -- <0.5 ml/kg/h 持续 6-12h
            -- 0 points: 肌酐 ≤1.2 mg/dL 和尿量充足
            WHEN creatinine_max <= 1.2 AND max_hours_low_05 = 0 THEN 0
            -- 缺失数据情况
            WHEN COALESCE(creatinine_max, max_hours_low_05) IS NULL THEN NULL
            ELSE 0
        END AS kidney,
        -- Hemostasis component
        CASE
            -- SOFA-2: 新阈值
            WHEN platelet_min <= 50 THEN 4
            WHEN platelet_min <= 80 THEN 3
            WHEN platelet_min <= 100 THEN 2
            WHEN platelet_min <= 150 THEN 1
            WHEN platelet_min IS NULL THEN NULL
            ELSE 0
        END AS hemostasis
    FROM co
    LEFT JOIN sedation_detection sd
        ON co.stay_id = sd.stay_id AND co.hr = sd.hr
    LEFT JOIN gcs_final gf
        ON co.stay_id = gf.stay_id AND co.hr = gf.hr
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
    LEFT JOIN bili
        ON co.stay_id = bili.stay_id AND co.hr = bili.hr
    LEFT JOIN cr
        ON co.stay_id = cr.stay_id AND co.hr = cr.hr
    LEFT JOIN bg_metabolic bgm
        ON co.stay_id = bgm.stay_id AND co.hr = bgm.hr
    LEFT JOIN rrt_metabolic_criteria rmc
        ON co.stay_id = rmc.stay_id AND co.hr = rmc.hr
    LEFT JOIN uo_max_durations uod
        ON co.stay_id = uod.stay_id AND co.hr = uod.hr
    LEFT JOIN rrt_status rrt
        ON co.stay_id = rrt.stay_id AND co.hr = rrt.hr
    LEFT JOIN plt
        ON co.stay_id = plt.stay_id AND co.hr = plt.hr
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
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    (COALESCE(brain, 0) + COALESCE(respiratory, 0) + COALESCE(cardiovascular, 0) +
     COALESCE(liver, 0) + COALESCE(kidney, 0) + COALESCE(hemostasis, 0)) AS sofa2_total
FROM scorecomp
WHERE hr >= 0
ORDER BY stay_id, hr;
