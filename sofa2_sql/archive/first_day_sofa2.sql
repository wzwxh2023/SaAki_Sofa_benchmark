-- =================================================================
-- Title: Sequential Organ Failure Assessment 2 (SOFA2) - First Day Score
-- Description: 首日SOFA2评分计算脚本
-- 基于SOFA2最新标准(JAMA 2025)，计算ICU患者首日的器官功能评分
--
-- SOFA2主要改进：
-- 1. 心血管系统评分优化 - 去甲肾上腺素+肾上腺素联合剂量计算
-- 2. 呼吸阈值更新 - 新的PaO2/FiO2临界值，支持高级呼吸支持
-- 3. 肾脏评分增强 - RRT标准+代谢指标综合评估
-- 4. 谵妄整合 - 神经系统评分纳入谵妄药物
-- 5. 术语更新 - "Brain"替代"CNS"，"Hemostasis"替代"Coagulation"
--
-- 数据源：
-- - mimiciv_derived.sofa2_scores (SOFA2每小时评分表)
-- - mimiciv_icu.icustays (ICU住院信息)
--
-- 时间窗口：ICU入院前6小时至ICU入院后24小时 (首日评估窗口)
-- =================================================================

-- 设置性能参数
SET work_mem = '512MB';
SET maintenance_work_mem = '512MB';
SET max_parallel_workers = 8;
SET max_parallel_workers_per_gather = 4;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
SET enable_parallel_hash = on;
SET jit = off;

-- =================================================================
-- 删除已存在的表
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.first_day_sofa2 CASCADE;

-- =================================================================
-- 计算首日SOFA2评分
-- =================================================================
CREATE TABLE mimiciv_derived.first_day_sofa2 AS
WITH
-- 定义首日时间窗口：ICU入院前6小时至ICU入院后24小时
sofa2_first_day_window AS (
    SELECT
        ie.stay_id,
        ie.hadm_id,
        ie.subject_id,
        ie.intime,
        ie.outtime,
        ie.intime - INTERVAL '6 hours' AS window_start_time,  -- ICU入院前6小时
        ie.intime + INTERVAL '24 hours' AS window_end_time,  -- ICU入院后24小时
        s2.hr,
        s2.starttime,
        s2.endtime,
        s2.brain,
        s2.respiratory,
        s2.cardiovascular,
        s2.liver,
        s2.kidney,
        s2.hemostasis,
        s2.sofa2_total
    FROM mimiciv_icu.icustays ie
    JOIN mimiciv_derived.sofa2_scores s2
        ON ie.stay_id = s2.stay_id
        AND s2.endtime >= ie.intime - INTERVAL '6 hours'
        AND s2.starttime <= ie.intime + INTERVAL '24 hours'
),

-- 计算首日最差评分（基于24小时滑动窗口）
first_day_worst_scores AS (
    SELECT
        stay_id,
        hadm_id,
        subject_id,
        intime,
        outtime,
        window_start_time,
        window_end_time,

        -- 计算各系统的首日最差评分
        MAX(brain) AS brain_worst,
        MAX(respiratory) AS respiratory_worst,
        MAX(cardiovascular) AS cardiovascular_worst,
        MAX(liver) AS liver_worst,
        MAX(kidney) AS kidney_worst,
        MAX(hemostasis) AS hemostasis_worst,

        -- 首日总评分 = 各系统最差评分之和
        MAX(brain) + MAX(respiratory) + MAX(cardiovascular) +
        MAX(liver) + MAX(kidney) + MAX(hemostasis) AS sofa2_first_day_total,

        -- 统计信息
        COUNT(*) AS hourly_measurements,
        MIN(starttime) AS first_measurement_time,
        MAX(endtime) AS last_measurement_time,

        -- ICU入院时刻的评分（基线）
        MAX(CASE WHEN hr = 0 THEN sofa2_total ELSE 0 END) AS sofa2_at_icu_admission
    FROM sofa2_first_day_window
    GROUP BY stay_id, hadm_id, subject_id, intime, outtime, window_start_time, window_end_time
),

-- 添加患者基本信息和住院信息
patient_demographics AS (
    SELECT
        fdw.*,
        pat.anchor_age AS age,  -- MIMIC-IV使用anchor_age而不是dob
        pat.gender,
        adm.race,
        adm.admission_type,
        adm.admission_location,
        adm.hospital_expire_flag,
        CASE
            WHEN adm.deathtime IS NOT NULL THEN 1
            ELSE 0
        END AS icu_mortality,
        ROUND(EXTRACT(EPOCH FROM (fdw.outtime - fdw.intime))/3600.0, 1) AS icu_los_hours,
        EXTRACT(EPOCH FROM (fdw.outtime - fdw.intime))/86400.0 AS icu_los_days
    FROM first_day_worst_scores fdw
    LEFT JOIN mimiciv_hosp.patients pat ON fdw.subject_id = pat.subject_id
    LEFT JOIN mimiciv_hosp.admissions adm ON fdw.hadm_id = adm.hadm_id
),

-- 添加临床状态信息
clinical_status AS (
    SELECT
        pd.*,
        CASE
            WHEN pd.sofa2_first_day_total >= 15 THEN 'Critical'
            WHEN pd.sofa2_first_day_total >= 12 THEN 'Severe'
            WHEN pd.sofa2_first_day_total >= 8 THEN 'Moderate'
            WHEN pd.sofa2_first_day_total >= 4 THEN 'Mild'
            ELSE 'Minimal'
        END AS severity_category,

        CASE
            WHEN pd.sofa2_first_day_total >= 2 THEN 1
            ELSE 0
        END AS organ_failure_flag,

        -- 计算器官系统衰竭数量（评分>=2的系统）
        (CASE WHEN pd.brain_worst >= 2 THEN 1 ELSE 0 END +
         CASE WHEN pd.respiratory_worst >= 2 THEN 1 ELSE 0 END +
         CASE WHEN pd.cardiovascular_worst >= 2 THEN 1 ELSE 0 END +
         CASE WHEN pd.liver_worst >= 2 THEN 1 ELSE 0 END +
         CASE WHEN pd.kidney_worst >= 2 THEN 1 ELSE 0 END +
         CASE WHEN pd.hemostasis_worst >= 2 THEN 1 ELSE 0 END) AS failing_organs_count
    FROM patient_demographics pd
)

-- 最终输出
SELECT
    -- 基础信息
    stay_id,
    hadm_id,
    subject_id,
    intime AS icu_intime,
    outtime AS icu_outtime,

    -- 首日SOFA2评分
    sofa2_first_day_total AS sofa2,
    brain_worst AS brain,
    respiratory_worst AS respiratory,
    cardiovascular_worst AS cardiovascular,
    liver_worst AS liver,
    kidney_worst AS kidney,
    hemostasis_worst AS hemostasis,

    -- 基线评分
    sofa2_at_icu_admission AS sofa2_icu_admission,

    -- 时间窗口信息
    window_start_time,
    window_end_time,
    first_measurement_time,
    last_measurement_time,
    hourly_measurements AS total_measurements,

    -- 患者人口学信息
    age,
    gender,
    race,
    admission_type,
    admission_location,

    -- 结局指标
    hospital_expire_flag,
    icu_mortality,
    icu_los_hours,
    icu_los_days,

    -- 临床分类
    severity_category,
    organ_failure_flag,
    failing_organs_count,

    -- 数据质量标记
    CASE
        WHEN hourly_measurements >= 24 THEN 'Complete'
        WHEN hourly_measurements >= 12 THEN 'Partial'
        WHEN hourly_measurements >= 6 THEN 'Limited'
        ELSE 'Insufficient'
    END AS data_completeness,

    -- 首日评分变化趋势
    CASE
        WHEN sofa2_first_day_total > sofa2_at_icu_admission THEN 'Worsening'
        WHEN sofa2_first_day_total < sofa2_at_icu_admission THEN 'Improving'
        WHEN sofa2_first_day_total = sofa2_at_icu_admission THEN 'Stable'
        ELSE 'Unknown'
    END AS trend_first_day

FROM clinical_status;

-- =================================================================
-- 添加主键和索引
-- =================================================================

-- 添加主键
ALTER TABLE mimiciv_derived.first_day_sofa2
ADD COLUMN first_day_sofa2_id SERIAL PRIMARY KEY;

-- 创建索引提高查询性能
CREATE INDEX idx_first_day_sofa2_stay_id ON mimiciv_derived.first_day_sofa2(stay_id);
CREATE INDEX idx_first_day_sofa2_subject_id ON mimiciv_derived.first_day_sofa2(subject_id);
CREATE INDEX idx_first_day_sofa2_hadm_id ON mimiciv_derived.first_day_sofa2(hadm_id);
CREATE INDEX idx_first_day_sofa2_sofa2_total ON mimiciv_derived.first_day_sofa2(sofa2);
CREATE INDEX idx_first_day_sofa2_severity ON mimiciv_derived.first_day_sofa2(severity_category);
CREATE INDEX idx_first_day_sofa2_mortality ON mimiciv_derived.first_day_sofa2(icu_mortality);

-- =================================================================
-- 添加表和列注释
-- =================================================================

-- 表注释
COMMENT ON TABLE mimiciv_derived.first_day_sofa2 IS
'首日SOFA2评分表 - 基于ICU入院前6小时至入院后24小时窗口计算的最差SOFA2评分。
符合SOFA2最新标准(JAMA 2025)，支持大规模临床研究和质量评估。';

-- 列注释
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.stay_id IS 'ICU住院ID';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.hadm_id IS '医院住院ID';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.subject_id IS '患者ID';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.icu_intime IS 'ICU入院时间';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.icu_outtime IS 'ICU出院时间';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.sofa2 IS '首日SOFA2总评分(0-24)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.brain IS '神经系统最差评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.respiratory IS '呼吸系统最差评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.cardiovascular IS '心血管系统最差评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.liver IS '肝脏系统最差评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.kidney IS '肾脏系统最差评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.hemostasis IS '凝血系统最差评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.sofa2_icu_admission IS 'ICU入院时刻SOFA2评分';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.window_start_time IS '评估窗口开始时间(ICU入院前6小时)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.window_end_time IS '评估窗口结束时间(ICU入院后24小时)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.total_measurements IS '窗口内小时级评分数量';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.age IS '患者年龄(岁)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.gender IS '患者性别';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.race IS '患者种族';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.hospital_expire_flag IS '医院死亡结局(1=死亡,0=存活)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.icu_los_hours IS 'ICU住院时长(小时)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.severity_category IS '严重程度分类(Minimal/Mild/Moderate/Severe/Critical)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.organ_failure_flag IS '器官功能衰竭标志(SOFA2>=2)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.failing_organs_count IS '衰竭器官数量(评分>=2的系统数)';
COMMENT ON COLUMN mimiciv_derived.first_day_sofa2.data_completeness IS '数据完整性分类(Complete/Partial/Limited/Insufficient)';

-- =================================================================
-- 生成统计报告
-- =================================================================

-- 基本统计
WITH stats AS (
    SELECT
        '=== 首日SOFA2评分表生成统计报告 ===' as report_title,
        '' as metric,
        '' as value,
        CURRENT_TIMESTAMP as generation_time

    UNION ALL

    SELECT
        '数据覆盖范围',
        '总ICU住院次数',
        CAST(COUNT(*) AS VARCHAR),
        NULL
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '评分分布',
        '平均SOFA2评分',
        CAST(ROUND(AVG(sofa2), 2) AS VARCHAR),
        NULL
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '评分分布',
        '中位数SOFA2评分',
        CAST(ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2)::numeric, 2) AS VARCHAR),
        NULL
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '评分分布',
        '最高SOFA2评分',
        CAST(MAX(sofa2) AS VARCHAR),
        NULL
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '严重程度分布',
        '重症患者比例(SOFA2>=8)',
        CAST(ROUND(COUNT(CASE WHEN sofa2 >= 8 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%',
        NULL
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '器官衰竭分析',
        '平均衰竭器官数量',
        CAST(ROUND(AVG(failing_organs_count), 2) AS VARCHAR),
        NULL
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '数据质量',
        '数据完整性',
        CAST(COUNT(CASE WHEN data_completeness = 'Complete' THEN 1 END) * 100.0 / COUNT(*) AS VARCHAR) || '%',
        NULL
    FROM mimiciv_derived.first_day_sofa2
)
SELECT * FROM stats WHERE metric IS NOT NULL OR report_title = '=== 首日SOFA2评分表生成统计报告 ===';

-- 更新表统计信息
ANALYZE mimiciv_derived.first_day_sofa2;

-- =================================================================
-- 脚本完成
-- =================================================================
SELECT
    '✅ 首日SOFA2评分表创建完成！' as status,
    '表名: mimiciv_derived.first_day_sofa2 | 记录数: ' || CAST(COUNT(*) AS VARCHAR) as message,
    '符合SOFA2最新标准(JAMA 2025)，支持临床研究和质量评估' as notes
FROM mimiciv_derived.first_day_sofa2;