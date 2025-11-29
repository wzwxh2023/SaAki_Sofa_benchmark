-- =================================================================
-- SOFA-2实现标准验证
-- 与原文JAMA 2025的SOFA-2定义进行对比
-- =================================================================

-- 检查我们SOFA-2实现的关键组件
SELECT '=== SOFA-2实现验证 ===' as verification_section
UNION ALL
SELECT '1. 脑神经系统评分标准' as component
UNION ALL
SELECT
    '   GCS标准: ' ||
    CASE
        WHEN COUNT(CASE WHEN s2.brain >= 1 THEN 1 END) > 0 THEN '✅ 有脑功能评分'
        ELSE '❌ 缺少脑功能评分'
    END as gcs_status
FROM mimiciv_derived.sofa2_scores s2
WHERE s2.sofa2_total IS NOT NULL
LIMIT 1
UNION ALL
SELECT '2. 呼吸系统评分标准' as component
UNION ALL
SELECT
    '   呼吸支持: ' ||
    CASE
        WHEN COUNT(CASE WHEN s2.respiratory >= 1 THEN 1 END) > 0 THEN '✅ 有呼吸评分'
        ELSE '❌ 缺少呼吸评分'
    END as resp_status
FROM mimiciv_derived.sofa2_scores s2
WHERE s2.sofa2_total IS NOT NULL
LIMIT 1
UNION ALL
SELECT '3. 心血管系统评分标准' as component
UNION ALL
SELECT
    '   血管活性药物: ' ||
    CASE
        WHEN COUNT(CASE WHEN s2.cardiovascular >= 1 THEN 1 END) > 0 THEN '✅ 有心血管评分'
        ELSE '❌ 缺少心血管评分'
    END as cardio_status
FROM mimiciv_derived.sofa2_scores s2
WHERE s2.sofa2_total IS NOT NULL
LIMIT 1;

-- 检查SOFA-2各器官系统的评分分布
WITH sofa2_components AS (
    SELECT
        brain,
        respiratory,
        cardiovascular,
        liver,
        kidney,
        hemostasis,
        sofa2_total
    FROM mimiciv_derived.sofa2_scores
    WHERE sofa2_total IS NOT NULL
    AND stay_id IN (
        SELECT stay_id FROM mimiciv_derived.first_day_sofa2 LIMIT 10000
    )
)
SELECT
    '=== SOFA-2组件评分分布 (前10K样本) ===' as distribution_section
UNION ALL
SELECT
    '脑神经系统 (Brain): 平均' || ROUND(AVG(brain), 2) ||
    ', 中位数' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY brain), 2) as brain_stats
FROM sofa2_components
UNION ALL
SELECT
    '呼吸系统 (Resp): 平均' || ROUND(AVG(respiratory), 2) ||
    ', 中位数' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY respiratory), 2) as resp_stats
FROM sofa2_components
UNION ALL
SELECT
    '心血管系统 (CV): 平均' || ROUND(AVG(cardiovascular), 2) ||
    ', 中位数' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cardiovascular), 2) as cv_stats
FROM sofa2_components
UNION ALL
SELECT
    '肝脏系统 (Liver): 平均' || ROUND(AVG(liver), 2) ||
    ', 中位数' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY liver), 2) as liver_stats
FROM sofa2_components
UNION ALL
SELECT
    '肾脏系统 (Kidney): 平均' || ROUND(AVG(kidney), 2) ||
    ', 中位数' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kidney), 2) as kidney_stats
FROM sofa2_components
UNION ALL
SELECT
    '凝血系统 (Hemostasis): 平均' || ROUND(AVG(hemostasis), 2) ||
    ', 中位数' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hemostasis), 2) as hemostasis_stats
FROM sofa2_components
UNION ALL
SELECT
    '总评分 (Total): 平均' || ROUND(AVG(sofa2_total), 2) ||
    ', 中位数' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_total), 2) as total_stats
FROM sofa2_components;

-- 对比SOFA-1 vs SOFA-2的评分差异
WITH sofa_comparison AS (
    SELECT
        fds.sofa as sofa1_score,
        fds2.sofa2 as sofa2_score,
        fds.stay_id
    FROM mimiciv_derived.first_day_sofa fds
    JOIN mimiciv_derived.first_day_sofa2 fds2 ON fds.stay_id = fds2.stay_id
    WHERE fds.sofa IS NOT NULL
    AND fds2.sofa2 IS NOT NULL
    LIMIT 5000
)
SELECT
    '=== SOFA-1 vs SOFA-2评分对比 (前5K样本) ===' as comparison_section
UNION ALL
SELECT
    'SOFA-1: 平均' || ROUND(AVG(sofa1_score), 2) ||
    ', 范围' || MIN(sofa1_score) || '-' || MAX(sofa1_score) as sofa1_stats
FROM sofa_comparison
UNION ALL
SELECT
    'SOFA-2: 平均' || ROUND(AVG(sofa2_score), 2) ||
    ', 范围' || MIN(sofa2_score) || '-' || MAX(sofa2_score) as sofa2_stats
FROM sofa_comparison
UNION ALL
SELECT
    '平均差异 (SOFA2-SOFA1): ' || ROUND(AVG(sofa2_score - sofa1_score), 2) as diff_stats
FROM sofa_comparison
UNION ALL
SELECT
    '相关系数: ' || ROUND(CORR(sofa1_score, sofa2_score), 3) as corr_stats
FROM sofa_comparison;