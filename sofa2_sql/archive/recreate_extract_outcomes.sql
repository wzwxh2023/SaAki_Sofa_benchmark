-- =================================================================
-- 从现有数据库表重建 extract_outcomes_final_fixed.sql
-- 基于已成功创建的 mimiciv_derived.patient_outcomes 表重建脚本
-- =================================================================

-- 创建表结构（基于现有表）
DROP TABLE IF EXISTS mimiciv_derived.patient_outcomes_restore CASCADE;

CREATE TABLE mimiciv_derived.patient_outcomes_restore AS
SELECT
    -- 基础标识符
    icu.subject_id,
    icu.hadm_id,
    icu.stay_id,

    -- 基本人口学信息
    pt.gender,
    pt.anchor_age,
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
    EXTRACT(EPOCH FROM (adm.dischtime - adm.admittime))/86400 AS hospital_los,
    adm.discharge_location,

    -- 死亡率结局
    adm.hospital_expire_flag AS hospital_mortality,
    CASE WHEN adm.deathtime IS NOT NULL
              AND adm.deathtime BETWEEN icu.intime AND COALESCE(icu.outtime, adm.deathtime)
         THEN 1 ELSE 0 END AS icu_mortality,

    -- 生存时间计算
    -- ICU-based Survival (天)
    CASE
        WHEN pt.dod IS NOT NULL THEN
            EXTRACT(EPOCH FROM (pt.dod - icu.intime))/86400
        ELSE
            EXTRACT(EPOCH FROM (COALESCE(icu.outtime, adm.dischtime) - icu.intime))/86400
    END AS icu_survival_days,

    -- Overall Survival (天)
    CASE
        WHEN pt.dod IS NOT NULL THEN
            EXTRACT(EPOCH FROM (pt.dod - adm.admittime))/86400
        ELSE
            EXTRACT(EPOCH FROM (adm.dischtime - adm.admittime))/86400
    END AS overall_survival_days,

    -- ICU入院前住院天数
    EXTRACT(EPOCH FROM (icu.intime - adm.admittime))/86400 AS pre_icu_hospital_days,

    -- ICU入院后28天和90天内死亡
    CASE
        WHEN pt.dod IS NOT NULL
             AND EXTRACT(EPOCH FROM (pt.dod - icu.intime))/86400 <= 28
        THEN 1 ELSE 0 END AS icu_death_within_28_days,
    CASE
        WHEN pt.dod IS NOT NULL
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

    -- 机械通气结局（简化版）
    COALESCE(vent.invasive_vent, 0) AS invasive_ventilation,
    COALESCE(vent.trach, 0) AS tracheostomy,
    COALESCE(vent.invasive_sessions, 0) AS invasive_vent_sessions,
    COALESCE(vent.total_sessions, 0) AS total_vent_sessions,

    -- RRT结局（简化版）
    COALESCE(rrt.required, 0) AS rrt_required,
    rrt.types,
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

FROM mimiciv_icu.icustays icu
LEFT JOIN mimiciv_hosp.admissions adm ON icu.hadm_id = adm.hadm_id
LEFT JOIN mimiciv_hosp.patients pt ON icu.subject_id = pt.subject_id
LEFT JOIN mimiciv_derived.first_day_sofa sofa ON icu.stay_id = sofa.stay_id
LEFT JOIN mimiciv_derived.first_day_sofa2 sofa2 ON icu.stay_id = sofa2.stay_id
LEFT JOIN mimiciv_derived.sepsis3 sep ON icu.stay_id = sep.stay_id
LEFT JOIN mimiciv_derived.sepsis3_sofa2_onset sep2 ON icu.stay_id = sep2.stay_id
LEFT JOIN (
    -- 机械通气子查询
    SELECT
        stay_id,
        MAX(CASE WHEN ventilation_status IN ('InvasiveVent', 'Tracheostomy') THEN 1 ELSE 0 END) AS invasive_vent,
        MAX(CASE WHEN ventilation_status = 'Tracheostomy' THEN 1 ELSE 0 END) AS trach,
        COUNT(CASE WHEN ventilation_status IN ('InvasiveVent', 'Tracheostomy') THEN 1 END) AS invasive_sessions,
        COUNT(*) AS total_sessions
    FROM mimiciv_derived.ventilation
    GROUP BY stay_id
) vent ON icu.stay_id = vent.stay_id
LEFT JOIN (
    -- RRT子查询
    SELECT
        stay_id,
        CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END AS required,
        STRING_AGG(DISTINCT dialysis_type, ', ') AS types,
        COUNT(*) AS sessions,
        SUM(CASE WHEN dialysis_active = 1 THEN 1 ELSE 0 END) AS hours,
        COUNT(CASE WHEN dialysis_type = 'CRRT' THEN 1 END) AS crrt,
        COUNT(CASE WHEN dialysis_type = 'CVVHDF' THEN 1 END) AS cvvhdf,
        COUNT(CASE WHEN dialysis_type = 'CVVHD' THEN 1 END) AS cvvhd,
        COUNT(CASE WHEN dialysis_type = 'CVVH' THEN 1 END) AS cvvh,
        COUNT(CASE WHEN dialysis_type = 'IHD' THEN 1 END) AS ihd,
        COUNT(CASE WHEN dialysis_type = 'Peritoneal' THEN 1 END) AS peritoneal,
        COUNT(CASE WHEN dialysis_type = 'SCUF' THEN 1 END) AS scuf
    FROM mimiciv_derived.rrt
    WHERE dialysis_type IS NOT NULL AND dialysis_type <> ''
    GROUP BY stay_id
) rrt ON icu.stay_id = rrt.stay_id
LEFT JOIN (
    -- ICU再入院子查询
    SELECT
        stay_id,
        CASE WHEN ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime) > 1
             THEN 1 ELSE 0 END AS icu_readmission,
        ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime) - 1 AS prior_icu_stays,
        ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime) AS icu_admission_number
    FROM mimiciv_icu.icustays
) icu_r ON icu.stay_id = icu_r.stay_id;

-- 验证数据一致性
SELECT
    'Data Validation' as status,
    COUNT(*) AS total_records,
    COUNT(CASE WHEN sofa_score > 0 THEN 1 END) AS has_sofa,
    COUNT(CASE WHEN sofa2_score > 0 THEN 1 END) AS has_sofa2,
    COUNT(CASE WHEN invasive_ventilation = 1 THEN 1 END) AS has_ventilation,
    COUNT(CASE WHEN rrt_required = 1 THEN 1 END) AS has_rrt,
    COUNT(CASE WHEN hospital_mortality = 1 THEN 1 END) AS hospital_deaths,
    COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) AS icu_deaths
FROM mimiciv_derived.patient_outcomes_restore;

-- 如果数据一致，可以替换原表
-- DROP TABLE mimiciv_derived.patient_outcomes;
-- ALTER TABLE mimiciv_derived.patient_outcomes_restore RENAME TO patient_outcomes;

-- 创建索引
CREATE INDEX idx_patient_outcomes_restore_subject ON mimiciv_derived.patient_outcomes_restore(subject_id);
CREATE INDEX idx_patient_outcomes_restore_stay ON mimiciv_derived.patient_outcomes_restore(stay_id);
CREATE INDEX idx_patient_outcomes_restore_hadm ON mimiciv_derived.patient_outcomes_restore(hadm_id);