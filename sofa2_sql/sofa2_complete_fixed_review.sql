-- =================================================================
-- SOFA-2 完整评分脚本（修复版本）
-- 基于数据库验证修复了表名和itemid问题
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

-- 步骤2.5: 为每个GCS记录标记镇静状态（关键修复）
, gcs_with_sedation_status AS (
    SELECT
        gc.stay_id,
        gc.charttime,
        gc.gcs_clean,
        gc.gcs_motor_clean,
        gc.gcs_verbal_clean,
        gc.gcs_eyes_clean,
        gc.is_complete,
        -- 检测在GCS记录时间点是否使用了镇静药物
        MAX(CASE
            WHEN pr.starttime <= gc.charttime
            AND COALESCE(pr.stoptime, gc.charttime) >= gc.charttime
            AND LOWER(pr.drug) LIKE ANY(ARRAY[
                '%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
                '%fentanyl%', '%remifentanil%', '%morphine%', '%hydromorphone%',
                '%dexmedetomidine%'
            ])
            THEN 1 ELSE 0
        END) AS on_sedation_meds_at_gcs,
        -- 检测在GCS记录时间点是否使用了肌松药物
        MAX(CASE
            WHEN pr.starttime <= gc.charttime
            AND COALESCE(pr.stoptime, gc.charttime) >= gc.charttime
            AND LOWER(pr.drug) LIKE ANY(ARRAY[
                '%cisatracurium%', '%vecuronium%', '%rocuronium%', '%atracurium%',
                '%succinylcholine%', '%pancuronium%'
            ])
            THEN 1 ELSE 0
        END) AS on_paralytics_at_gcs,
        -- 检测在GCS记录时间点的RASS评分
        MAX(CASE
            WHEN ce.charttime = gc.charttime
            AND ce.itemid IN (223900, 220739)
            AND ce.valuenum IS NOT NULL
            AND CAST(ce.valuenum AS NUMERIC) <= -4
            THEN 1 ELSE 0
        END) AS deep_sedation_at_gcs
    FROM gcs_clean gc
    LEFT JOIN mimiciv_icu.icustays icu
        ON gc.stay_id = icu.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr
        ON icu.hadm_id = pr.hadm_id
    LEFT JOIN mimiciv_icu.chartevents ce
        ON gc.stay_id = ce.stay_id
        AND ce.charttime = gc.charttime
        AND ce.itemid IN (223900, 220739)
    GROUP BY gc.stay_id, gc.charttime, gc.gcs_clean, gc.gcs_motor_clean,
             gc.gcs_verbal_clean, gc.gcs_eyes_clean, gc.is_complete
)

-- 步骤3: 智能GCS选择（镇静前回溯修复）
, gcs_forward_fill AS (
    SELECT
        co.stay_id,
        co.hr,
        co.starttime,
        co.endtime,
        gcs_lookup.nearest_gcs,
        gcs_lookup.nearest_motor,
        gcs_lookup.nearest_verbal,
        gcs_lookup.nearest_eyes,
        gcs_lookup.is_sedated_at_selected_gcs,
        gcs_lookup.has_current_gcs,
        gcs_lookup.selected_gcs_time
    FROM co
    LEFT JOIN LATERAL (
        -- 智能GCS选择逻辑：如果当前镇静，回溯到最近非镇静的GCS
        WITH current_hour_sedation AS (
            SELECT
                MAX(COALESCE(on_sedation_meds, 0)) as sedation_flag,
                MAX(COALESCE(on_paralytics, 0)) as paralytics_flag,
                MAX(COALESCE(deep_sedation, 0)) as deep_sedation_flag
            FROM sedation_detection sd
            WHERE sd.stay_id = co.stay_id AND sd.hr = co.hr
        ),
        gcs_candidates AS (
            SELECT
                gss.charttime,
                gss.gcs_clean,
                gss.gcs_motor_clean,
                gss.gcs_verbal_clean,
                gss.gcs_eyes_clean,
                gss.is_complete,
                gss.on_sedation_meds_at_gcs,
                gss.on_paralytics_at_gcs,
                gss.deep_sedation_at_gcs,
                -- 标记是否镇静状态
                CASE WHEN (gss.on_sedation_meds_at_gcs = 1
                         OR gss.on_paralytics_at_gcs = 1
                         OR gss.deep_sedation_at_gcs = 1)
                     THEN 1 ELSE 0 END as is_sedated
            FROM gcs_with_sedation_status gss
            WHERE gss.stay_id = co.stay_id
              AND gss.charttime <= co.endtime
              AND gss.is_complete = 1  -- 只要完整的GCS记录
        ),
        final_selection AS (
            SELECT
                charttime,
                gcs_clean,
                gcs_motor_clean,
                gcs_verbal_clean,
                gcs_eyes_clean,
                is_sedated,
                -- 标记当前小时内是否有GCS
                CASE WHEN charttime >= co.starttime AND charttime < co.endtime
                     THEN 1 ELSE 0 END as is_current_hour
            FROM gcs_candidates
            ORDER BY
                -- 优先级1: 如果当前小时有非镇静GCS，优先选择
                CASE WHEN is_current_hour = 1 AND is_sedated = 0 THEN 0 ELSE 1 END,
                -- 优先级2: 非镇静状态优先
                is_sedated,
                -- 优先级3: 时间最近优先
                charttime DESC
            LIMIT 1
        )
        SELECT
            gcs_clean AS nearest_gcs,
            gcs_motor_clean AS nearest_motor,
            gcs_verbal_clean AS nearest_verbal,
            gcs_eyes_clean AS nearest_eyes,
            is_sedated AS is_sedated_at_selected_gcs,
            is_current_hour AS has_current_gcs,
            charttime AS selected_gcs_time
        FROM final_selection
    ) gcs_lookup ON TRUE
)

-- 步骤4: 最终GCS数据处理
, gcs_final AS (
    SELECT
        stay_id,
        hr,
        nearest_gcs AS gcs_min,
        nearest_motor AS motor_component,
        nearest_verbal AS verbal_component,
        nearest_eyes AS eyes_component,
        has_current_gcs,
        is_sedated_at_selected_gcs,
        selected_gcs_time,
        CASE
            -- 如果没有可用GCS数据
            WHEN nearest_gcs IS NULL THEN NULL
            -- 如果有完整的GCS记录，使用总分
            WHEN nearest_motor IS NOT NULL AND nearest_verbal IS NOT NULL AND nearest_eyes IS NOT NULL
            THEN nearest_gcs
            -- 如果缺失组件，使用运动评分（SOFA-2 fallback规则）
            WHEN nearest_motor IS NOT NULL THEN nearest_motor
            ELSE NULL
        END AS effective_gcs
    FROM gcs_forward_fill
    WHERE (has_current_gcs = 1 OR nearest_gcs IS NOT NULL)  -- 确保有GCS数据才保留
)

-- 步骤5: 谵妄药物检测
, brain_delirium AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN pr.starttime::date <= co.endtime::date
            AND COALESCE(pr.stoptime::date, co.endtime::date) >= co.starttime::date
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

    -- 方法2: 从chartevents获取CPAP/BiPAP/HFNC支持
    SELECT
        ce.stay_id,
        ce.charttime AS starttime,
        ce.charttime + INTERVAL '5 MINUTE' AS endtime,  -- 假设单次记录代表5分钟支持
        CASE
            WHEN ce.itemid IN (227583, 227287) THEN 'CPAP'
            WHEN ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582, 227288) THEN 'BiPAP'
            -- WHEN ce.itemid IN (226708) THEN 'HFNC'  -- itemid不存在，已删除
            ELSE 'Other_High_Support'
        END AS ventilation_status,
        1 AS has_advanced_support,
        'chartevents_cpap' AS source
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (227287, 227288, 227577, 227578, 227579, 227580, 227581, 227582, 227583)
      AND ce.valuenum IS NOT NULL
      AND (ce.valuenum > 0 OR ce.value IS NOT NULL)
)

-- 高级呼吸支持时间窗口合并（避免短暂事件漏标）
, advanced_support_sessions AS (
    SELECT
        stay_id,
        ventilation_status,
        starttime,
        endtime,
        SUM(new_session) OVER (
            PARTITION BY stay_id, ventilation_status
            ORDER BY starttime
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS session_id
    FROM (
        SELECT
            stay_id,
            ventilation_status,
            starttime,
            endtime,
            CASE
                WHEN starttime - LAG(endtime) OVER (
                    PARTITION BY stay_id, ventilation_status
                    ORDER BY starttime
                ) <= INTERVAL '30 MINUTE'
                THEN 0
                ELSE 1
            END AS new_session
        FROM advanced_resp_support
    ) ordered_events
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
            GREATEST(
                EXTRACT(EPOCH FROM (
                    LEAST(asm.event_endtime, co.endtime) - GREATEST(asm.event_starttime, co.starttime)
                )),
                0
            )
        ) / 60 AS advanced_support_minutes_in_hour
    FROM co
    LEFT JOIN advanced_support_merged asm
        ON co.stay_id = asm.stay_id
        AND asm.event_starttime < co.endtime
        AND asm.event_endtime > co.starttime
    GROUP BY co.stay_id, co.hr, co.starttime, co.endtime
)

-- ECMO机械支持检测（基于数据库验证的有效方法）
, mechanical_support AS (
    SELECT DISTINCT
        ce.stay_id,
        ce.charttime,
        'ECMO' AS device_type,
        1 AS has_mechanical_support
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 224660  -- 仅保留有效的ECMO检测itemid
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
        COALESCE(MAX(rtw.any_advanced_support_in_hour), 0) AS has_advanced_support
    FROM co
    LEFT JOIN spo2_data spo2
        ON co.stay_id = spo2.stay_id
        AND spo2.charttime >= co.starttime
        AND spo2.charttime < co.endtime
    LEFT JOIN fio2_chart_data fio2
        ON co.stay_id = fio2.stay_id
        AND fio2.charttime >= co.starttime
        AND fio2.charttime < co.endtime
    LEFT JOIN respiratory_time_windows rtw
        ON co.stay_id = rtw.stay_id
        AND co.hr = rtw.hr
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
        COALESCE(
            MAX(pafi.on_advanced_support),
            MAX(sfi.has_advanced_support),
            MAX(rtw.any_advanced_support_in_hour),
            0
        ) AS has_advanced_support,
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
    LEFT JOIN respiratory_time_windows rtw
        ON co.stay_id = rtw.stay_id AND co.hr = rtw.hr
    GROUP BY co.stay_id, co.hr
)

-- ECMO检测（仅保留验证有效的方法2和4）
, ecmo_resp AS (
    SELECT DISTINCT
        co.stay_id,
        co.hr,
        MAX(CASE
            -- 方法2: 通过机械支持表检测ECMO（验证有效）
            WHEN ms.has_mechanical_support = 1 AND ms.device_type = 'ECMO'
                 AND ms.charttime >= co.starttime AND ms.charttime < co.endtime THEN 1
            -- 方法4: 通过procedureevents检测ECMO操作（验证有效）
            WHEN pe.starttime < co.endtime
                 AND COALESCE(pe.endtime, pe.starttime) > co.starttime
                 AND pe.itemid IN (229529, 229530)  -- ECMO Inflow/Outflow Line
            THEN 1
            ELSE 0
        END) AS on_ecmo
    FROM co
    LEFT JOIN mechanical_support ms
        ON co.stay_id = ms.stay_id
    LEFT JOIN mimiciv_icu.procedureevents pe
        ON co.stay_id = pe.stay_id
    WHERE ms.device_type = 'ECMO'
       OR pe.itemid IN (229529, 229530)
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
    SELECT
        co.stay_id,
        co.hr,
        MAX(va.norepinephrine) AS rate_norepinephrine,
        MAX(va.epinephrine) AS rate_epinephrine,
        MAX(va.dopamine) AS rate_dopamine,
        MAX(va.dobutamine) AS rate_dobutamine,
        MAX(va.vasopressin) AS rate_vasopressin,
        MAX(va.phenylephrine) AS rate_phenylephrine,
        MAX(va.milrinone) AS rate_milrinone
    FROM co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
    GROUP BY co.stay_id, co.hr
)

-- 机械循环支持按小时聚合（供心血管评分使用）
, mech_support_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(ms.has_mechanical_support) AS has_mechanical_support
    FROM co
    LEFT JOIN mechanical_support ms
        ON co.stay_id = ms.stay_id
        AND ms.charttime >= co.starttime
        AND ms.charttime < co.endtime
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

-- 患者体重（用于基于体重的尿量计算）- 修复表名
, patient_weight AS (
    SELECT
        stay_id,
        weight
    FROM mimiciv_derived.first_day_weight
    WHERE weight IS NOT NULL AND weight > 0
)

-- RRT检测
-- RRT代谢标准
-- SOFA-2 肾脏评分：精确连续尿量分析
, uo_continuous AS (
    -- 步骤1: 原始尿量数据与体重 - 修复表名引用
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
    SELECT
        co.stay_id,
        co.hr,
        COALESCE(rrt_state.dialysis_active, 0) AS on_rrt
    FROM co
    LEFT JOIN LATERAL (
        SELECT r.dialysis_active
        FROM mimiciv_derived.rrt r
        WHERE r.stay_id = co.stay_id
          AND r.charttime <= co.endtime
        ORDER BY r.charttime DESC
        LIMIT 1
    ) rrt_state ON TRUE
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
        gf.effective_gcs AS gcs_min,
        sd.on_sedation_meds,
        sd.on_paralytics,
        sd.deep_sedation,
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
        vp.rate_dopamine,
        vp.rate_dobutamine,
        vp.rate_vasopressin,
        vp.rate_phenylephrine,
        vp.rate_milrinone,
        COALESCE(ms.has_mechanical_support, 0) AS has_mechanical_support,
        -- Liver
        bili.bilirubin_max,
        -- Kidney
        cr.creatinine_max,
        cr.potassium_max,
        bgm.ph_min,
        bgm.bicarbonate_min,
        uod.max_hours_low_05,
        uod.max_hours_low_03,
        uod.max_hours_anuria,
        rrt.on_rrt,
        -- Hemostasis
        plt.platelet_min,
        -- Brain component (SOFA-2 Compliant)
        CASE
            -- 正常GCS评分逻辑
            WHEN effective_gcs <= 5 THEN 4
            WHEN effective_gcs BETWEEN 6 AND 8 THEN 3
            WHEN effective_gcs BETWEEN 9 AND 12 THEN 2
            WHEN effective_gcs BETWEEN 13 AND 14 THEN 1
            -- GCS = 15 且无谵妄药物时为0分
            WHEN effective_gcs = 15 AND COALESCE(on_delirium_med, 0) = 0 THEN 0
            -- 任何患者使用谵妄药物最少得1分
            WHEN COALESCE(on_delirium_med, 0) = 1 THEN 1
            -- 缺失数据情况：无任何可用GCS记录时返回NULL
            WHEN effective_gcs IS NULL THEN NULL
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
            -- 4分：机械循环支持或NE/Epi高剂量
            WHEN COALESCE(has_mechanical_support, 0) = 1 THEN 4
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.4 THEN 4
            -- 4分：中剂量NE/Epi + 其他升压/正性肌力药
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4
                 AND (
                    COALESCE(rate_dopamine, 0) > 0
                    OR COALESCE(rate_dobutamine, 0) > 0
                    OR COALESCE(rate_vasopressin, 0) > 0
                    OR COALESCE(rate_phenylephrine, 0) > 0
                    OR COALESCE(rate_milrinone, 0) > 0
                 ) THEN 4
            -- 3分：中剂量NE/Epi
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4 THEN 3
            -- 3分：低剂量NE/Epi + 其他药
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2
                 AND (
                    COALESCE(rate_dopamine, 0) > 0
                    OR COALESCE(rate_dobutamine, 0) > 0
                    OR COALESCE(rate_vasopressin, 0) > 0
                    OR COALESCE(rate_phenylephrine, 0) > 0
                    OR COALESCE(rate_milrinone, 0) > 0
                 ) THEN 3
            -- 2分：低剂量NE/Epi
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2 THEN 2
            -- 多巴胺单药评分
            WHEN COALESCE(rate_dopamine, 0) > 40
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) = 0
                 AND COALESCE(rate_dobutamine, 0) = 0
                 AND COALESCE(rate_vasopressin, 0) = 0
                 AND COALESCE(rate_phenylephrine, 0) = 0
                 AND COALESCE(rate_milrinone, 0) = 0 THEN 4
            WHEN COALESCE(rate_dopamine, 0) > 20
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) = 0
                 AND COALESCE(rate_dobutamine, 0) = 0
                 AND COALESCE(rate_vasopressin, 0) = 0
                 AND COALESCE(rate_phenylephrine, 0) = 0
                 AND COALESCE(rate_milrinone, 0) = 0 THEN 3
            WHEN COALESCE(rate_dopamine, 0) > 0
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) = 0
                 AND COALESCE(rate_dobutamine, 0) = 0
                 AND COALESCE(rate_vasopressin, 0) = 0
                 AND COALESCE(rate_phenylephrine, 0) = 0
                 AND COALESCE(rate_milrinone, 0) = 0 THEN 2
            -- 2分：其他升压/正性肌力药
            WHEN COALESCE(rate_dobutamine, 0) > 0
                 OR COALESCE(rate_vasopressin, 0) > 0
                 OR COALESCE(rate_phenylephrine, 0) > 0
                 OR COALESCE(rate_milrinone, 0) > 0
                 OR COALESCE(rate_dopamine, 0) > 0 THEN 2
            -- 替代评分：仅在无血管活性药物数据时使用MAP评分
            WHEN mbp_min IS NOT NULL
                 AND COALESCE(rate_norepinephrine, 0) = 0
                 AND COALESCE(rate_epinephrine, 0) = 0
                 AND COALESCE(rate_dopamine, 0) = 0
                 AND COALESCE(rate_dobutamine, 0) = 0
                 AND COALESCE(rate_vasopressin, 0) = 0
                 AND COALESCE(rate_phenylephrine, 0) = 0
                 AND COALESCE(rate_milrinone, 0) = 0 THEN
                CASE
                    WHEN mbp_min >= 70 THEN 0
                    WHEN mbp_min >= 60 THEN 1
                    WHEN mbp_min >= 50 THEN 2
                    WHEN mbp_min >= 40 THEN 3
                    ELSE 4
                END
            ELSE NULL
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
            WHEN (
                (
                    COALESCE(creatinine_max, 0) > 1.2
                    OR COALESCE(max_hours_low_03, 0) >= 6
                )
                AND (
                    COALESCE(potassium_max, 0) >= 6.0
                    OR (
                        COALESCE(ph_min, 7.3) <= 7.2
                        AND COALESCE(bicarbonate_min, 100) <= 12
                    )
                )
            ) THEN 4
            -- 3 points: 肌酐 >3.5 mg/dL 或严重少尿/无尿
            WHEN cr.creatinine_max > 3.5 THEN 3
            WHEN uod.max_hours_low_03 >= 24 THEN 3  -- <0.3 ml/kg/h 持续 ≥24h
            WHEN uod.max_hours_anuria >= 12 THEN 3      -- 完全无尿 ≥12h
            -- 2 points: 肌酐 2.0-3.5 mg/dL 或中度少尿 (≥12h)
            WHEN cr.creatinine_max > 2.0 AND cr.creatinine_max <= 3.5 THEN 2
            WHEN uod.max_hours_low_05 >= 12 THEN 2      -- <0.5 ml/kg/h 持续 ≥12h
            -- 1 point: 肌酐 1.2-2.0 mg/dL 或轻度少尿 (6-12h)
            WHEN cr.creatinine_max > 1.2 AND cr.creatinine_max <= 2.0 THEN 1
            WHEN uod.max_hours_low_05 >= 6 AND uod.max_hours_low_05 < 12 THEN 1  -- <0.5 ml/kg/h 持续 6-12h
            -- 0 points: 肌酐 ≤1.2 mg/dL 和尿量充足
            WHEN cr.creatinine_max <= 1.2 AND COALESCE(uod.max_hours_low_05, 0) = 0 THEN 0
            -- 缺失数据情况
            WHEN COALESCE(cr.creatinine_max, uod.max_hours_low_05) IS NULL THEN NULL
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
    LEFT JOIN mech_support_hourly ms
        ON co.stay_id = ms.stay_id AND co.hr = ms.hr
    LEFT JOIN bili
        ON co.stay_id = bili.stay_id AND co.hr = bili.hr
    LEFT JOIN cr
        ON co.stay_id = cr.stay_id AND co.hr = cr.hr
    LEFT JOIN bg_metabolic bgm
        ON co.stay_id = bgm.stay_id AND co.hr = bgm.hr
    LEFT JOIN uo_max_durations uod
        ON co.stay_id = uod.stay_id AND co.hr = uod.hr
    LEFT JOIN rrt_status rrt
        ON co.stay_id = rrt.stay_id AND co.hr = rrt.hr
    LEFT JOIN plt
        ON co.stay_id = plt.stay_id AND co.hr = plt.hr
)

-- =================================================================
-- SOFA-2 最终评分（参考SOFA1的24小时窗口实现）
-- =================================================================
, score_final AS (
    SELECT s.*
        -- Combine all the scores to get SOFA-2
        -- Impute 0 if the score is missing
        -- the window function takes the max over the last 24 hours (参考SOFA1官方实现)
        , COALESCE(
            MAX(brain) OVER w
            , 0) AS brain_24hours
        , COALESCE(
            MAX(respiratory) OVER w
            , 0) AS respiratory_24hours
        , COALESCE(
            MAX(cardiovascular) OVER w
            , 0) AS cardiovascular_24hours
        , COALESCE(
            MAX(liver) OVER w
            , 0) AS liver_24hours
        , COALESCE(
            MAX(kidney) OVER w
            , 0) AS kidney_24hours
        , COALESCE(
            MAX(hemostasis) OVER w
            , 0) AS hemostasis_24hours

        -- sum together data for final SOFA-2 (基于24小时窗口最大值)
        , COALESCE(
            MAX(brain) OVER w
            , 0)
        + COALESCE(
            MAX(respiratory) OVER w
            , 0)
        + COALESCE(
            MAX(cardiovascular) OVER w
            , 0)
        + COALESCE(
            MAX(liver) OVER w
            , 0)
        + COALESCE(
            MAX(kidney) OVER w
            , 0)
        + COALESCE(
            MAX(hemostasis) OVER w
            , 0)
        AS sofa2_24hours
    FROM scorecomp s
    WINDOW w AS
        (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING
        )
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
    -- 当前小时的组件评分（原始数据）
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    -- SOFA-2标准：过去24小时窗口内的最差评分
    brain_24hours,
    respiratory_24hours,
    cardiovascular_24hours,
    liver_24hours,
    kidney_24hours,
    hemostasis_24hours,
    -- 辅助信息
    ratio_type,
    oxygen_ratio,
    has_advanced_support,
    on_ecmo,
    -- SOFA-2总分（基于24小时窗口）
    sofa2_24hours
FROM score_final
WHERE hr >= 0
ORDER BY stay_id, hr;