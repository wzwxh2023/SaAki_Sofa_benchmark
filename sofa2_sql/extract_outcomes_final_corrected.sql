-- =================================================================
-- 提取患者结局变量脚本（修正版）
-- 机械通气按照四分类系统：InvasiveVent, NonInvasiveVent, HFNC, SupplementalOxygen/None
-- 计算分开的通气时长
-- =================================================================

-- 删除已存在的表
DROP TABLE IF EXISTS mimiciv_derived.patient_outcomes CASCADE;

-- 创建结局变量表
CREATE TABLE mimiciv_derived.patient_outcomes AS
WITH

-- ICU基本信息
icu_info AS (
    SELECT
        subject_id,
        hadm_id,
        stay_id,
        first_careunit,
        last_careunit,
        intime,
        outtime,
        los
    FROM mimiciv_icu.icustays
),

-- 住院基本信息
hosp_info AS (
    SELECT
        hadm_id,
        admittime,
        dischtime,
        deathtime,
        admission_type,
        admission_location,
        discharge_location,
        insurance,
        hospital_expire_flag,
        race
    FROM mimiciv_hosp.admissions
),

-- 患者基本信息
patient_info AS (
    SELECT
        subject_id,
        gender,
        anchor_age,
        anchor_year,
        dod
    FROM mimiciv_hosp.patients
),

-- SOFA评分
sofa_info AS (
    SELECT
        stay_id,
        sofa,
        respiration,
        coagulation,
        liver,
        cardiovascular,
        cns,
        renal
    FROM mimiciv_derived.first_day_sofa
),

-- SOFA2评分
sofa2_info AS (
    SELECT
        stay_id,
        sofa2_total,
        respiratory,
        hemostasis,
        liver,
        cardiovascular,
        brain,
        kidney
    FROM mimiciv_derived.first_day_sofa2
),

-- ICU再入院信息
icu_readmit AS (
    SELECT
        subject_id,
        stay_id,
        ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime) AS icu_admission_number,
        ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime) - 1 AS prior_icu_stays,
        CASE WHEN ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime) > 1
             THEN 1 ELSE 0 END AS icu_readmission
    FROM mimiciv_icu.icustays
),

-- 机械通气结局（四分类系统，分开计算时长）
ventilation_info AS (
    SELECT
        v.stay_id,
        -- 四分类呼吸支持
        MAX(CASE WHEN v.ventilation_status = 'InvasiveVent' THEN 1 ELSE 0 END) AS invasive_vent,
        MAX(CASE WHEN v.ventilation_status = 'Tracheostomy' THEN 1 ELSE 0 END) AS tracheostomy,
        MAX(CASE WHEN v.ventilation_status = 'NonInvasiveVent' THEN 1 ELSE 0 END) AS noninvasive_vent,
        MAX(CASE WHEN v.ventilation_status = 'HFNC' THEN 1 ELSE 0 END) AS hfnc,
        MAX(CASE WHEN v.ventilation_status IN ('SupplementalOxygen', 'None') THEN 1 ELSE 0 END) AS oxygen_only,

        -- 各类通气时长计算（小时）
        -- 有创通气时长（InvasiveVent + Tracheostomy）
        SUM(GREATEST(0, EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status IN ('InvasiveVent', 'Tracheostomy')
                 THEN LEAST(v.endtime, icu.outtime) - GREATEST(v.starttime, icu.intime) ELSE INTERVAL '0' END
        ))/3600)) AS invasive_ventilation_hours,

        -- 无创通气时长
        SUM(GREATEST(0, EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status = 'NonInvasiveVent'
                 THEN LEAST(v.endtime, icu.outtime) - GREATEST(v.starttime, icu.intime) ELSE INTERVAL '0' END
        ))/3600)) AS noninvasive_ventilation_hours,

        -- HFNC时长
        SUM(GREATEST(0, EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status = 'HFNC'
                 THEN LEAST(v.endtime, icu.outtime) - GREATEST(v.starttime, icu.intime) ELSE INTERVAL '0' END
        ))/3600)) AS hfnc_hours,

        -- 高级呼吸支持总时长（InvasiveVent + NonInvasiveVent + HFNC + Tracheostomy）
        SUM(GREATEST(0, EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy')
                 THEN LEAST(v.endtime, icu.outtime) - GREATEST(v.starttime, icu.intime) ELSE INTERVAL '0' END
        ))/3600)) AS advanced_respiratory_support_hours,

        -- 从ICU入院到首次各类通气的时间（小时）
        MIN(EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status = 'InvasiveVent'
                 THEN GREATEST(v.starttime - icu.intime, INTERVAL '0') ELSE NULL END
        ))/3600) AS time_to_invasive_vent_hours,
        MIN(EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status = 'NonInvasiveVent'
                 THEN GREATEST(v.starttime - icu.intime, INTERVAL '0') ELSE NULL END
        ))/3600) AS time_to_noninvasive_vent_hours,
        MIN(EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status = 'HFNC'
                 THEN GREATEST(v.starttime - icu.intime, INTERVAL '0') ELSE NULL END
        ))/3600) AS time_to_hfnc_hours,
        MIN(EXTRACT(EPOCH FROM (
            CASE WHEN v.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy')
                 THEN GREATEST(v.starttime - icu.intime, INTERVAL '0') ELSE NULL END
        ))/3600) AS time_to_advanced_support_hours

    FROM mimiciv_derived.ventilation v
    JOIN mimiciv_icu.icustays icu ON v.stay_id = icu.stay_id
    GROUP BY v.stay_id, icu.intime
),

-- 血管活性药物基础区间（裁剪至ICU、需有任一剂量>0）
vaso_base AS (
    SELECT
        v.stay_id,
        GREATEST(v.starttime, icu.intime) AS starttime,
        LEAST(v.endtime, icu.outtime) AS endtime
    FROM mimiciv_derived.vasoactive_agent v
    JOIN icu_info icu ON v.stay_id = icu.stay_id
    WHERE v.starttime IS NOT NULL
      AND v.endtime IS NOT NULL
      AND LEAST(v.endtime, icu.outtime) > GREATEST(v.starttime, icu.intime)
      AND (
          COALESCE(v.dopamine, 0) +
          COALESCE(v.epinephrine, 0) +
          COALESCE(v.norepinephrine, 0) +
          COALESCE(v.phenylephrine, 0) +
          COALESCE(v.vasopressin, 0) +
          COALESCE(v.dobutamine, 0) +
          COALESCE(v.milrinone, 0)
      ) > 0
),
-- 血管活性药物事件（扫描线合并重叠/联用）
vaso_events AS (
    SELECT stay_id, starttime AS event_time, 1 AS delta FROM vaso_base
    UNION ALL
    SELECT stay_id, endtime AS event_time, -1 AS delta FROM vaso_base
),
vaso_coverage AS (
    SELECT
        stay_id,
        event_time,
        SUM(delta) OVER (PARTITION BY stay_id ORDER BY event_time, delta DESC) AS active_count,
        LEAD(event_time) OVER (PARTITION BY stay_id ORDER BY event_time, delta DESC) AS next_time
    FROM vaso_events
),
-- 血管活性药物使用时长（小时）
vasoactive_info AS (
    SELECT
        stay_id,
        SUM(
            CASE
                WHEN active_count > 0 AND next_time IS NOT NULL
                    THEN GREATEST(0, EXTRACT(EPOCH FROM (next_time - event_time)) / 3600)
                ELSE 0
            END
        ) AS vasoactive_hours
    FROM vaso_coverage
    GROUP BY stay_id
),

-- RRT结局
rrt_info AS (
    WITH rrt_durations AS (
        SELECT
            r.*,
            -- 使用下一个charttime推断间隔，末行假设1小时；负值截断为0
            GREATEST(
                0,
                EXTRACT(
                    EPOCH FROM (
                        COALESCE(
                            LEAD(r.charttime) OVER (PARTITION BY r.stay_id ORDER BY r.charttime),
                            r.charttime + INTERVAL '1 hour'
                        ) - r.charttime
                    )
                ) / 3600
            ) AS interval_hours
        FROM mimiciv_derived.rrt r
        WHERE r.dialysis_type IS NOT NULL AND r.dialysis_type <> ''
    )
    SELECT
        r.stay_id,
        -- 是否需要RRT
        CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END AS required,
        -- RRT类型列表
        STRING_AGG(DISTINCT r.dialysis_type, ', ') AS types,
        -- RRT记录条数（近似会话数，保持与原先口径一致）
        COUNT(*) AS sessions,
        -- RRT总时长（小时），按charttime间隔累加，仅计active=1
        SUM(CASE WHEN r.dialysis_active = 1 THEN r.interval_hours ELSE 0 END) AS hours,
        -- 各类型RRT记录数量
        COUNT(CASE WHEN r.dialysis_type = 'CRRT' THEN 1 END) AS crrt,
        COUNT(CASE WHEN r.dialysis_type = 'CVVHDF' THEN 1 END) AS cvvhdf,
        COUNT(CASE WHEN r.dialysis_type = 'CVVHD' THEN 1 END) AS cvvhd,
        COUNT(CASE WHEN r.dialysis_type = 'CVVH' THEN 1 END) AS cvvh,
        COUNT(CASE WHEN r.dialysis_type = 'IHD' THEN 1 END) AS ihd,
        COUNT(CASE WHEN r.dialysis_type = 'Peritoneal' THEN 1 END) AS peritoneal,
        COUNT(CASE WHEN r.dialysis_type = 'SCUF' THEN 1 END) AS scuf
    FROM rrt_durations r
    GROUP BY r.stay_id
),

-- Sepsis信息
sepsis_info AS (
    SELECT
        stay_id,
        sepsis3
    FROM mimiciv_derived.sepsis3
),

sepsis2_info AS (
    SELECT
        stay_id,
        sepsis3_sofa2
    FROM mimiciv_derived.sepsis3_sofa2_onset
)

-- 主查询：组合所有结局变量
SELECT
    -- 基础标识符
    icu.subject_id,
    icu.hadm_id,
    icu.stay_id,

    -- 基本人口学信息
    pt.gender,
    -- 精确年龄：anchor_age + (icu年 - anchor_year)
    pt.anchor_age + EXTRACT(YEAR FROM icu.intime) - pt.anchor_year AS anchor_age_exact,
    adm.race,
    adm.insurance,
    adm.admission_type,
    adm.admission_location,

    -- ICU和住院信息
    icu.first_careunit,
    icu.last_careunit,
    icu.intime AS icu_intime,
    icu.outtime AS icu_outtime,
    icu.los AS icu_los,
    adm.admittime AS adm_admittime,
    adm.dischtime AS adm_dischtime,
    adm.deathtime AS adm_deathtime,
    pt.dod AS patient_dod,
    EXTRACT(EPOCH FROM (adm.dischtime - adm.admittime))/86400 AS hospital_los,
    adm.discharge_location,

    -- 死亡率结局
    adm.hospital_expire_flag AS hospital_mortality,
    CASE WHEN adm.deathtime IS NOT NULL
              AND adm.deathtime BETWEEN icu.intime AND COALESCE(icu.outtime, adm.deathtime)
         THEN 1 ELSE 0 END AS icu_mortality,

    -- 生存分析字段（确保日粒度一致，避免Timestamp/Date混减误差）
    CASE
        WHEN adm.deathtime IS NOT NULL OR pt.dod IS NOT NULL THEN 1
        ELSE 0
    END AS event_status,
    -- 从ICU入科到结局（死亡优先deathtime，其次dod；存活取出院），按日期差计算并截断为非负
    GREATEST(
        0,
        (
            COALESCE(adm.deathtime::date, pt.dod::date, adm.dischtime::date)
            - icu.intime::date
        )::float
    ) AS survival_days,
    -- 死亡且在入科后365天内的标记（0/1）
    CASE
        WHEN (adm.deathtime IS NOT NULL OR pt.dod IS NOT NULL)
             AND (
                 COALESCE(adm.deathtime::date, pt.dod::date) - icu.intime::date
             ) >= 0
             AND (
                 COALESCE(adm.deathtime::date, pt.dod::date) - icu.intime::date
             ) <= 365
        THEN 1 ELSE 0 END AS mortality_1yr,

    -- ICU入院前住院天数
    GREATEST(0, EXTRACT(EPOCH FROM (icu.intime - adm.admittime))/86400) AS pre_icu_hospital_days,

    -- ICU入院后28天和90天内死亡
    CASE
        WHEN pt.dod IS NOT NULL AND pt.dod >= icu.intime
             AND EXTRACT(EPOCH FROM (pt.dod - icu.intime))/86400 <= 28
        THEN 1 ELSE 0 END AS icu_death_within_28_days,
    CASE
        WHEN pt.dod IS NOT NULL AND pt.dod >= icu.intime
             AND EXTRACT(EPOCH FROM (pt.dod - icu.intime))/86400 <= 90
        THEN 1 ELSE 0 END AS icu_death_within_90_days,

    -- 死亡地点分类
    CASE
        WHEN pt.dod IS NOT NULL AND adm.hospital_expire_flag = 1 THEN 'In-hospital'
        WHEN pt.dod IS NOT NULL AND adm.hospital_expire_flag = 0 THEN 'Post-discharge'
        ELSE 'Alive'
    END AS death_location,

    -- SOFA评分
    COALESCE(sofa.sofa, 0) AS sofa_score,
    sofa.respiration AS sofa_respiration,
    sofa.coagulation AS sofa_coagulation,
    sofa.liver AS sofa_liver,
    sofa.cardiovascular AS sofa_cardiovascular,
    sofa.cns AS sofa_cns,
    sofa.renal AS sofa_renal,

    -- SOFA2评分
    COALESCE(sofa2.sofa2_total, 0) AS sofa2_score,
    sofa2.respiratory AS sofa2_respiratory,
    sofa2.hemostasis AS sofa2_hemostasis,
    sofa2.liver AS sofa2_liver,
    sofa2.cardiovascular AS sofa2_cardiovascular,
    sofa2.brain AS sofa2_brain,
    sofa2.kidney AS sofa2_kidney,

    -- Sepsis诊断
    CASE WHEN sep.sepsis3 = true THEN 1 ELSE 0 END AS sepsis3_sofa,
    CASE WHEN sep2.sepsis3_sofa2 = true THEN 1 ELSE 0 END AS sepsis3_sofa2,

    -- 机械通气结局（四分类系统）
    COALESCE(vent.invasive_vent, 0) AS invasive_ventilation,
    COALESCE(vent.tracheostomy, 0) AS tracheostomy,
    COALESCE(vent.noninvasive_vent, 0) AS noninvasive_ventilation,
    COALESCE(vent.hfnc, 0) AS hfnc_ventilation,
    COALESCE(vent.oxygen_only, 0) AS oxygen_only,
    COALESCE(vent.invasive_ventilation_hours, 0) AS invasive_ventilation_hours,
    COALESCE(vent.noninvasive_ventilation_hours, 0) AS noninvasive_ventilation_hours,
    COALESCE(vent.hfnc_hours, 0) AS hfnc_hours,
    COALESCE(vent.advanced_respiratory_support_hours, 0) AS advanced_respiratory_support_hours,
    COALESCE(vent.time_to_invasive_vent_hours, 0) AS time_to_invasive_vent_hours,
    COALESCE(vent.time_to_noninvasive_vent_hours, 0) AS time_to_noninvasive_vent_hours,
    COALESCE(vent.time_to_hfnc_hours, 0) AS time_to_hfnc_hours,
    COALESCE(vent.time_to_advanced_support_hours, 0) AS time_to_advanced_support_hours,

    -- 血管活性药物结局
    COALESCE(vaso.vasoactive_hours, 0) AS vasoactive_hours,

    -- RRT结局
    COALESCE(rrt.required, 0) AS rrt_required,
    rrt.types AS rrt_types,
    COALESCE(rrt.sessions, 0) AS rrt_sessions,
    COALESCE(rrt.hours, 0) AS rrt_hours,
    COALESCE(rrt.crrt, 0) AS crrt_sessions,
    COALESCE(rrt.cvvhdf, 0) AS cvvhdf_sessions,
    COALESCE(rrt.cvvhd, 0) AS cvvhd_sessions,
    COALESCE(rrt.cvvh, 0) AS cvvh_sessions,
    COALESCE(rrt.ihd, 0) AS ihd_sessions,
    COALESCE(rrt.peritoneal, 0) AS peritoneal_sessions,
    COALESCE(rrt.scuf, 0) AS scuf_sessions,

    -- ICU再入院
    icu_r.icu_readmission,
    icu_r.prior_icu_stays,
    icu_r.icu_admission_number

FROM icu_info icu
LEFT JOIN hosp_info adm ON icu.hadm_id = adm.hadm_id
LEFT JOIN patient_info pt ON icu.subject_id = pt.subject_id
LEFT JOIN sofa_info sofa ON icu.stay_id = sofa.stay_id
LEFT JOIN sofa2_info sofa2 ON icu.stay_id = sofa2.stay_id
LEFT JOIN sepsis_info sep ON icu.stay_id = sep.stay_id
LEFT JOIN sepsis2_info sep2 ON icu.stay_id = sep2.stay_id
LEFT JOIN ventilation_info vent ON icu.stay_id = vent.stay_id
LEFT JOIN vasoactive_info vaso ON icu.stay_id = vaso.stay_id
LEFT JOIN rrt_info rrt ON icu.stay_id = rrt.stay_id
LEFT JOIN icu_readmit icu_r ON icu.stay_id = icu_r.stay_id;

-- 创建索引
CREATE INDEX idx_patient_outcomes_subject ON mimiciv_derived.patient_outcomes(subject_id);
CREATE INDEX idx_patient_outcomes_stay ON mimiciv_derived.patient_outcomes(stay_id);
CREATE INDEX idx_patient_outcomes_hadm ON mimiciv_derived.patient_outcomes(hadm_id);
CREATE INDEX idx_patient_outcomes_mortality ON mimiciv_derived.patient_outcomes(hospital_mortality);
CREATE INDEX idx_patient_outcomes_icu_mortality ON mimiciv_derived.patient_outcomes(icu_mortality);
CREATE INDEX idx_patient_outcomes_sepsis ON mimiciv_derived.patient_outcomes(sepsis3_sofa2);
CREATE INDEX idx_patient_outcomes_invasive_vent ON mimiciv_derived.patient_outcomes(invasive_ventilation);
CREATE INDEX idx_patient_outcomes_rrt ON mimiciv_derived.patient_outcomes(rrt_required);

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.patient_outcomes IS 'Comprehensive patient outcomes including SOFA/SOFA2 scores, mortality, ventilation (4-category), RRT, and survival times';

-- 数据验证查询
-- SELECT
--     COUNT(*) AS total_records,
--     COUNT(CASE WHEN sofa_score > 0 THEN 1 END) AS has_sofa,
--     COUNT(CASE WHEN sofa2_score > 0 THEN 1 END) AS has_sofa2,
--     COUNT(CASE WHEN invasive_ventilation = 1 THEN 1 END) AS has_invasive_vent,
--     COUNT(CASE WHEN noninvasive_ventilation = 1 THEN 1 END) AS has_noninvasive_vent,
--     COUNT(CASE WHEN hfnc_ventilation = 1 THEN 1 END) AS has_hfnc,
--     COUNT(CASE WHEN rrt_required = 1 THEN 1 END) AS has_rrt
-- FROM mimiciv_derived.patient_outcomes;
