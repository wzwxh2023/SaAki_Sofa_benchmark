-- =================================================================
-- SOFA-2 评分系统 - 阶段1: 基础数据预处理
-- 基于sofa2_optimized.sql的前几个步骤
-- =================================================================

-- 基础配置
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET temp_buffers = '64MB';
SET statement_timeout = '7200s';
SET client_min_messages = 'INFO';

-- 删除已存在的临时表
DROP TABLE IF EXISTS sofa2_stage1_sedation_hourly CASCADE;
DROP TABLE IF EXISTS sofa2_stage1_delirium_hourly CASCADE;
DROP TABLE IF EXISTS sofa2_stage1_gcs_hourly CASCADE;

-- =================================================================
-- 基础ICU数据准备
-- =================================================================

-- 基础ICU小时数据（用于后续连接）
CREATE TEMP TABLE base_icu_hourly AS
SELECT ih.stay_id, ie.hadm_id, ie.subject_id
    , hr
    , ih.endtime - INTERVAL '1 HOUR' AS starttime
    , ih.endtime
FROM mimiciv_derived.icustay_hourly ih
INNER JOIN mimiciv_icu.icustays ie
    ON ih.stay_id = ie.stay_id;

-- =================================================================
-- 步骤1: 预处理药物列表（统一维护，避免重复）
-- =================================================================

CREATE TEMP TABLE drug_params AS
SELECT UNNEST(ARRAY[
    '%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
    '%dexmedetomidine%', '%ketamine%', '%clonidine%', '%etomidate%'
]) AS sedation_pattern;

CREATE TEMP TABLE delirium_params AS
SELECT UNNEST(ARRAY[
    '%haloperidol%', '%haldol%', '%quetiapine%', '%seroquel%',
    '%olanzapine%', '%zyprexa%', '%risperidone%', '%risperdal%',
    '%ziprasidone%', '%geodon%', '%clozapine%', '%aripiprazole%'
]) AS delirium_pattern;

-- =================================================================
-- 步骤2: 预计算镇静药物输注时段（智能时间边界处理）
-- =================================================================

CREATE TEMP TABLE sedation_infusion_periods AS
SELECT
    ie.stay_id,
    pr.starttime,
    pr.drug,  -- 保留drug字段，用于后续谵妄药物匹配
    -- 智能时间边界处理：基于实际数据统计和临床合理性
    CASE
        -- 情况1: 有明确停止时间且合理，使用实际时间
        WHEN pr.stoptime IS NOT NULL
             AND pr.stoptime > pr.starttime
             AND EXTRACT(EPOCH FROM (pr.stoptime - pr.starttime)) BETWEEN 3600 AND 604800  -- 1小时-7天
        THEN pr.stoptime

        -- 情况2: 有停止时间但过短(<1小时)，可能是推注误分类，延长到合理时间
        WHEN pr.stoptime IS NOT NULL
             AND pr.stoptime > pr.starttime
             AND EXTRACT(EPOCH FROM (pr.stoptime - pr.starttime)) < 3600
        THEN pr.starttime + INTERVAL '4 hours'

        -- 情况3: 有停止时间但过长(>7天)，可能是数据错误，截断到合理范围
        WHEN pr.stoptime IS NOT NULL
             AND pr.stoptime > pr.starttime
             AND EXTRACT(EPOCH FROM (pr.stoptime - pr.starttime)) > 604800
        THEN pr.starttime + INTERVAL '7 days'

        -- 情况4: 无停止时间，基于ICU出院时间和药物类型设置合理上限
        WHEN pr.stoptime IS NULL THEN
            LEAST(
                ie.outtime,  -- 不超过ICU出院时间
                CASE
                    -- 不同药物设置不同的默认持续时间
                    WHEN pr.drug ILIKE '%propofol%' THEN pr.starttime + INTERVAL '24 hours'
                    WHEN pr.drug ILIKE '%midazolam%' THEN pr.starttime + INTERVAL '48 hours'
                    WHEN pr.drug ILIKE '%dexmedetomidine%' THEN pr.starttime + INTERVAL '12 hours'
                    WHEN pr.drug ILIKE '%lorazepam%' THEN pr.starttime + INTERVAL '24 hours'
                    WHEN pr.drug ILIKE '%diazepam%' THEN pr.starttime + INTERVAL '24 hours'
                    ELSE pr.starttime + INTERVAL '24 hours'  -- 默认24小时
                END
            )

        ELSE pr.stoptime  -- 其他情况使用原始值
    END AS stoptime,
    -- 药物类型标识：精确匹配镇静药物（排除镇痛药）
    CASE WHEN EXISTS (
        SELECT 1 FROM drug_params dp
        WHERE LOWER(pr.drug) LIKE dp.sedation_pattern
    ) THEN 1 ELSE 0 END AS is_sedation_drug
FROM mimiciv_icu.icustays ie
LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE pr.starttime IS NOT NULL
  -- 只考虑持续输注途径（更精确的镇静给药方式）
  AND pr.route IN ('IV DRIP', 'IV', 'Intravenous', 'IVPCA', 'SC', 'IM');

-- =================================================================
-- 步骤3: 预计算每小时的镇静状态（性能优化：批量计算）
-- =================================================================

CREATE TEMP TABLE sofa2_stage1_sedation_hourly AS
SELECT
    base.stay_id,
    base.hr,
    base.starttime,
    base.endtime,
    -- 使用聚合函数避免复杂的LATERAL JOIN
    MAX(CASE
        WHEN base.starttime BETWEEN sip.starttime AND sip.stoptime
        AND sip.is_sedation_drug = 1
        THEN 1
        ELSE 0
    END) AS sedation,
    -- 计算当前小时内同时使用的镇静药物数量
    COUNT(CASE
        WHEN base.starttime BETWEEN sip.starttime AND sip.stoptime
        AND sip.is_sedation_drug = 1
        THEN 1
        ELSE NULL
    END) AS sedation_drug_count
FROM base_icu_hourly base
LEFT JOIN sedation_infusion_periods sip
    ON base.stay_id = sip.stay_id
    AND base.starttime BETWEEN sip.starttime AND sip.stoptime
    AND sip.is_sedation_drug = 1
GROUP BY base.stay_id, base.hr, base.starttime, base.endtime;

-- =================================================================
-- 步骤4: 预处理每小时的谵妄药物使用情况（保持原有逻辑）
-- =================================================================

CREATE TEMP TABLE sofa2_stage1_delirium_hourly AS
SELECT
    base.stay_id,
    base.hr,
    base.starttime,
    base.endtime,
    -- 使用优化后的药物匹配逻辑，确保与原有逻辑完全一致
    MAX(CASE
        WHEN EXISTS (
            SELECT 1 FROM sedation_infusion_periods sip2
            WHERE base.stay_id = sip2.stay_id
            AND base.starttime BETWEEN sip2.starttime AND sip2.stoptime
            AND EXISTS (
                SELECT 1 FROM delirium_params dp
                WHERE LOWER(sip2.drug) LIKE dp.delirium_pattern
            )
        ) THEN 1 ELSE 0
    END) AS delirium,
    -- 计算当前小时内使用的谵妄药物数量
    COUNT(CASE
        WHEN EXISTS (
            SELECT 1 FROM sedation_infusion_periods sip2
            WHERE base.stay_id = sip2.stay_id
            AND base.starttime BETWEEN sip2.starttime AND sip2.stoptime
            AND EXISTS (
                SELECT 1 FROM delirium_params dp
                WHERE LOWER(sip2.drug) LIKE dp.delirium_pattern
            )
        ) THEN 1 ELSE NULL
    END) AS delirium_drug_count
FROM base_icu_hourly base
GROUP BY base.stay_id, base.hr, base.starttime, base.endtime;

-- =================================================================
-- 步骤5: 优化的GCS数据处理（简化版本）
-- =================================================================

CREATE TEMP TABLE sofa2_stage1_gcs_hourly AS
SELECT
    base.stay_id,
    base.hr,
    base.starttime,
    base.endtime,
    -- 使用EXISTS优化逻辑，避免不必要的连接
    COALESCE(
        (SELECT MAX(gcs.gcs)
         FROM mimiciv_derived.gcs gcs
         WHERE gcs.stay_id = base.stay_id
         AND gcs.charttime BETWEEN base.starttime AND base.endtime
         AND gcs.gcs IS NOT NULL),
        NULL
    ) AS gcs,
    -- 提供缺失值标识，便于后续处理
    CASE WHEN EXISTS (
        SELECT 1 FROM mimiciv_derived.gcs gcs
        WHERE gcs.stay_id = base.stay_id
        AND gcs.charttime BETWEEN base.starttime AND base.endtime
        AND gcs.gcs IS NOT NULL
    ) THEN 0 ELSE 1 END AS gcs_missing
FROM base_icu_hourly base;

-- =================================================================
-- 阶段1完成报告
-- =================================================================

SELECT
    'Stage 1: Basic Preprocessing - COMPLETED' as stage_status,
    (SELECT COUNT(*) FROM sofa2_stage1_sedation_hourly) as sedation_records,
    (SELECT COUNT(*) FROM sofa2_stage1_delirium_hourly) as delirium_records,
    (SELECT COUNT(*) FROM sofa2_stage1_gcs_hourly) as gcs_records,
    NOW() as completion_time;

-- 显示各阶段的样本数据
SELECT '=== Sedation Hourly Sample ===' as info;
SELECT * FROM sofa2_stage1_sedation_hourly LIMIT 5;

SELECT '=== Delirium Hourly Sample ===' as info;
SELECT * FROM sofa2_stage1_delirium_hourly LIMIT 5;

SELECT '=== GCS Hourly Sample ===' as info;
SELECT * FROM sofa2_stage1_gcs_hourly LIMIT 5;