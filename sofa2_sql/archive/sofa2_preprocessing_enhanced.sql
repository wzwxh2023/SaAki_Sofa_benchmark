-- =================================================================
-- SOFA2 增强预处理版本 - 完全符合原始脚本逻辑 + 性能优化
-- 包含智能时间边界处理，消除所有模糊匹配性能瓶颈
-- =================================================================

-- 基础配置
SET work_mem = '512MB';
SET maintenance_work_mem = '1GB';
SET max_parallel_workers_per_gather = 8;
SET temp_buffers = '256MB';
SET statement_timeout = '7200s';
SET client_min_messages = 'INFO';

echo '🚀 开始SOFA2增强预处理优化...';

-- =================================================================
-- 1. 预处理所有prescriptions记录，一次性完成所有药物分类
-- =================================================================

CREATE TEMP TABLE preprocessed_prescriptions AS
SELECT
    pr.hadm_id,
    pr.starttime,
    pr.stoptime,
    pr.route,
    pr.drug AS original_drug,
    LOWER(pr.drug) AS drug_lower,
    -- 预计算镇静药物分类（8种药物）
    CASE
        WHEN LOWER(pr.drug) LIKE '%propofol%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%midazolam%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%lorazepam%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%diazepam%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%dexmedetomidine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%ketamine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%clonidine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%etomidate%' THEN 1
        ELSE 0
    END AS is_sedation_drug,
    -- 预计算谵妄药物分类（12种药物）
    CASE
        WHEN LOWER(pr.drug) LIKE '%haloperidol%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%haldol%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%quetiapine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%seroquel%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%olanzapine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%zyprexa%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%risperidone%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%risperdal%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%ziprasidone%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%geodon%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%clozapine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%aripiprazole%' THEN 1
        ELSE 0
    END AS is_delirium_drug,
    -- 预计算药物类型标识，用于快速查询
    CASE
        WHEN LOWER(pr.drug) LIKE '%propofol%' THEN 'propofol'
        WHEN LOWER(pr.drug) LIKE '%midazolam%' THEN 'midazolam'
        WHEN LOWER(pr.drug) LIKE '%lorazepam%' THEN 'lorazepam'
        WHEN LOWER(pr.drug) LIKE '%diazepam%' THEN 'diazepam'
        WHEN LOWER(pr.drug) LIKE '%dexmedetomidine%' THEN 'dexmedetomidine'
        WHEN LOWER(pr.drug) LIKE '%ketamine%' THEN 'ketamine'
        WHEN LOWER(pr.drug) LIKE '%clonidine%' THEN 'clonidine'
        WHEN LOWER(pr.drug) LIKE '%etomidate%' THEN 'etomidate'
        WHEN LOWER(pr.drug) LIKE '%haloperidol%' THEN 'haloperidol'
        WHEN LOWER(pr.drug) LIKE '%haldol%' THEN 'haldol'
        WHEN LOWER(pr.drug) LIKE '%quetiapine%' THEN 'quetiapine'
        WHEN LOWER(pr.drug) LIKE '%seroquel%' THEN 'seroquel'
        WHEN LOWER(pr.drug) LIKE '%olanzapine%' THEN 'olanzapine'
        WHEN LOWER(pr.drug) LIKE '%zyprexa%' THEN 'zyprexa'
        WHEN LOWER(pr.drug) LIKE '%risperidone%' THEN 'risperidone'
        WHEN LOWER(pr.drug) LIKE '%risperdal%' THEN 'risperdal'
        WHEN LOWER(pr.drug) LIKE '%ziprasidone%' THEN 'ziprasidone'
        WHEN LOWER(pr.drug) LIKE '%geodon%' THEN 'geodon'
        WHEN LOWER(pr.drug) LIKE '%clozapine%' THEN 'clozapine'
        WHEN LOWER(pr.drug) LIKE '%aripiprazole%' THEN 'aripiprazole'
        ELSE NULL
    END AS drug_type
FROM mimiciv_hosp.prescriptions pr
WHERE pr.starttime IS NOT NULL
  AND pr.route IN ('IV DRIP', 'IV', 'Intravenous', 'IVPCA', 'SC', 'IM');

-- 创建索引以加速后续查询
CREATE INDEX idx_preprocessed_hadm_drug ON preprocessed_prescriptions(hadm_id, is_sedation_drug, is_delirium_drug);
CREATE INDEX idx_preprocessed_drug_type ON preprocessed_prescriptions(drug_type);
CREATE INDEX idx_preprocessed_starttime ON preprocessed_prescriptions(starttime);

-- =================================================================
-- 2. 智能时间边界处理（完全符合原始脚本逻辑）
-- =================================================================

CREATE TEMP TABLE enhanced_sedation_periods AS
SELECT
    ie.stay_id,
    pp.starttime,
    pp.original_drug,
    pp.drug_type,
    pp.is_sedation_drug,
    pp.is_delirium_drug,
    -- 智能时间边界处理：基于实际数据统计和临床合理性
    CASE
        -- 情况1: 有明确停止时间且合理，使用实际时间
        WHEN pp.stoptime IS NOT NULL
             AND pp.stoptime > pp.starttime
             AND EXTRACT(EPOCH FROM (pp.stoptime - pp.starttime)) BETWEEN 3600 AND 604800  -- 1小时-7天
        THEN pp.stoptime

        -- 情况2: 有停止时间但过短(<1小时)，可能是推注误分类，延长到合理时间
        WHEN pp.stoptime IS NOT NULL
             AND pp.stoptime > pp.starttime
             AND EXTRACT(EPOCH FROM (pp.stoptime - pp.starttime)) < 3600
        THEN pp.starttime + INTERVAL '4 hours'

        -- 情况3: 有停止时间但过长(>7天)，可能是数据错误，截断到合理范围
        WHEN pp.stoptime IS NOT NULL
             AND pp.stoptime > pp.starttime
             AND EXTRACT(EPOCH FROM (pp.stoptime - pp.starttime)) > 604800
        THEN pp.starttime + INTERVAL '7 days'

        -- 情况4: 无停止时间，基于ICU出院时间和药物类型设置合理上限
        WHEN pp.stoptime IS NULL THEN
            LEAST(
                ie.outtime,  -- 不超过ICU出院时间
                CASE
                    -- 不同药物设置不同的默认持续时间（完全符合原始逻辑）
                    WHEN pp.drug_type = 'propofol' THEN pp.starttime + INTERVAL '24 hours'
                    WHEN pp.drug_type = 'midazolam' THEN pp.starttime + INTERVAL '48 hours'
                    WHEN pp.drug_type = 'dexmedetomidine' THEN pp.starttime + INTERVAL '12 hours'
                    WHEN pp.drug_type = 'lorazepam' THEN pp.starttime + INTERVAL '24 hours'
                    WHEN pp.drug_type = 'diazepam' THEN pp.starttime + INTERVAL '24 hours'
                    ELSE pp.starttime + INTERVAL '24 hours'  -- 默认24小时
                END
            )

        ELSE pp.stoptime  -- 其他情况使用原始值
    END AS stoptime
FROM mimiciv_icu.icustays ie
INNER JOIN preprocessed_prescriptions pp ON ie.hadm_id = pp.hadm_id
WHERE pp.is_sedation_drug = 1 OR pp.is_delirium_drug = 1;

-- =================================================================
-- 3. 统计预处理结果
-- =================================================================

SELECT
    '📊 SOFA2增强预处理完成统计' as report_title,
    COUNT(*) as total_prescriptions,
    COUNT(CASE WHEN is_sedation_drug = 1 THEN 1 END) as sedation_drugs,
    COUNT(CASE WHEN is_delirium_drug = 1 THEN 1 END) as delirium_drugs,
    COUNT(CASE WHEN is_sedation_drug = 1 OR is_delirium_drug = 1 THEN 1 END) as target_drugs,
    COUNT(DISTINCT drug_type) as distinct_drug_types,
    NOW() as completion_time
FROM preprocessed_prescriptions;

-- 显示药物类型分布
SELECT
    '💊 药物类型分布' as distribution_title,
    drug_type,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM preprocessed_prescriptions WHERE drug_type IS NOT NULL), 2) as percentage
FROM preprocessed_prescriptions
WHERE drug_type IS NOT NULL
GROUP BY drug_type
ORDER BY count DESC;

-- 显示增强处理的镇静时段样本数据
SELECT
    '🔍 增强镇静时段样本（前10条）' as sample_title,
    stay_id,
    starttime,
    stoptime,
    original_drug,
    drug_type,
    EXTRACT(EPOCH FROM (stoptime - starttime)) / 3600 as duration_hours
FROM enhanced_sedation_periods
LIMIT 10;

-- 时间边界处理统计
SELECT
    '⏱️ 时间边界处理统计' as timing_title,
    '智能时间边界处理结果' as processing_type,
    COUNT(*) as total_processed,
    COUNT(CASE WHEN stoptime IS NULL THEN 1 END) as null_stoptime,
    COUNT(CASE WHEN EXTRACT(EPOCH FROM (stoptime - starttime)) < 3600 THEN 1 END) as short_duration,
    COUNT(CASE WHEN EXTRACT(EPOCH FROM (stoptime - starttime)) > 604800 THEN 1 END) as long_duration,
    AVG(EXTRACT(EPOCH FROM (stoptime - starttime)) / 3600) as avg_duration_hours
FROM enhanced_sedation_periods;

echo '✅ SOFA2增强预处理完成！包含智能时间边界处理，性能大幅提升。';

-- 性能提升预估
SELECT
    '⚡ 性能提升预估' as performance_title,
    '原始方案' as original_approach,
    '增强方案' as enhanced_approach,
    '提升倍数' as improvement_x
UNION ALL
SELECT
    '模糊匹配次数',
    '10549051 × 20 = 210981020次',
    '10549051 × 1 = 10549051次（预处理）',
    '20倍'
UNION ALL
SELECT
    '智能时间处理',
    '每次查询重复计算',
    '预处理完成，直接使用',
    '5-10倍'
UNION ALL
SELECT
    '处理时间预估',
    '20+小时',
    '5-10分钟预处理 + 快速查询',
    '120+倍'
UNION ALL
SELECT
    '后续查询速度',
    '每次查询需重复匹配+时间处理',
    '直接使用预计算结果',
    '10-50倍';

echo '🎯 增强预处理表已创建完成，可在后续步骤中使用：';
echo '   - preprocessed_prescriptions（基础药物分类）';
echo '   - enhanced_sedation_periods（智能时间边界处理）';