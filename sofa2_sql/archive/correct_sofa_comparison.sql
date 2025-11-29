-- =================================================================
-- SOFA-1 vs SOFA-2脓毒症患者对比分析 (修复重复计数问题)
-- 确保每个stay_id只计算一次
-- =================================================================

-- 1. 基本统计对比 (修复版)
SELECT '=== 基本统计对比 (修复重复计数) ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者数: ' || COUNT(DISTINCT fds.stay_id)::text FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
WHERE fds.sofa >= 2 AND soi.suspected_infection = 1
    AND fds.stay_id IS NOT NULL

UNION ALL
SELECT 'SOFA-2脓毒症患者数: ' || COUNT(DISTINCT fds2.stay_id)::text FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.stay_id IS NOT NULL;

-- 2. 使用更准确的方法：先找到每个stay_id最早的感染时间，然后关联SOFA评分
WITH first_suspicion AS (
    SELECT
        stay_id,
        MIN(suspected_infection_time) as first_infection_time
    FROM mimiciv_derived.suspicion_of_infection
    WHERE suspected_infection = 1 AND stay_id IS NOT NULL
    GROUP BY stay_id
),

sofa1_sepsis_unique AS (
    SELECT DISTINCT
        fds.stay_id,
        fds.sofa as sofa_score
    FROM mimiciv_derived.first_day_sofa fds
    JOIN first_suspicion fs ON fds.stay_id = fs.stay_id
    WHERE fds.sofa >= 2
        AND fds.endtime >= (fs.first_infection_time - INTERVAL '48 hours')
        AND fds.endtime <= (fs.first_infection_time + INTERVAL '24 hours')
),

sofa2_sepsis_unique AS (
    SELECT DISTINCT
        fds2.stay_id,
        fds2.sofa2 as sofa_score
    FROM mimiciv_derived.first_day_sofa2 fds2
    JOIN first_suspicion fs ON fds2.stay_id = fs.stay_id
    WHERE fds2.sofa2 >= 2
        AND fds2.window_end_time >= (fs.first_infection_time - INTERVAL '48 hours')
        AND fds2.window_end_time <= (fs.first_infection_time + INTERVAL '24 hours')
)

-- 3. 修正后的统计
SELECT '=== 修正后的脓毒症统计 ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者数: ' || COUNT(*)::text FROM sofa1_sepsis_unique

UNION ALL
SELECT 'SOFA-2脓毒症患者数: ' || COUNT(*)::text FROM sofa2_sepsis_unique

UNION ALL
SELECT 'SOFA-1平均评分: ' || ROUND(AVG(sofa_score), 2)::text FROM sofa1_sepsis_unique

UNION ALL
SELECT 'SOFA-2平均评分: ' || ROUND(AVG(sofa_score), 2)::text FROM sofa2_sepsis_unique

UNION ALL
SELECT 'SOFA-1评分范围: ' || MIN(sofa_score)::text || '-' || MAX(sofa_score)::text FROM sofa1_sepsis_unique

UNION ALL
SELECT 'SOFA-2评分范围: ' || MIN(sofa_score)::text || '-' || MAX(sofa_score)::text FROM sofa2_sepsis_unique

UNION ALL
SELECT 'SOFA-1评分中位数: ' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_score), 1)::text FROM sofa1_sepsis_unique

UNION ALL
SELECT 'SOFA-2评分中位数: ' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_score), 1)::text FROM sofa2_sepsis_unique;

-- 4. 重叠分析 (修正版)
SELECT '=== 重叠分析 (修正版) ===' as section
UNION ALL
SELECT '重叠患者数: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM sofa1_sepsis_unique INTERSECT SELECT stay_id FROM sofa2_sepsis_unique
) overlap

UNION ALL
SELECT '仅SOFA-1脓毒症: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM sofa1_sepsis_unique EXCEPT SELECT stay_id FROM sofa2_sepsis_unique
) only_sofa1

UNION ALL
SELECT '仅SOFA-2脓毒症: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM sofa2_sepsis_unique EXCEPT SELECT stay_id FROM sofa1_sepsis_unique
) only_sofa2

UNION ALL
SELECT '重叠比例: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (
        SELECT stay_id FROM sofa1_sepsis_unique INTERSECT SELECT stay_id FROM sofa2_sepsis_unique
    ) overlap) /
    (SELECT COUNT(*)::numeric FROM sofa1_sepsis_unique) * 100, 1
)::text || '%' as overlap_pct

UNION ALL
SELECT 'SOFA-1独占比例: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (
        SELECT stay_id FROM sofa1_sepsis_unique EXCEPT SELECT stay_id FROM sofa2_sepsis_unique
    ) only_sofa1) /
    (SELECT COUNT(*)::numeric FROM sofa1_sepsis_unique) * 100, 1
)::text || '%' as sofa1_only_pct

UNION ALL
SELECT 'SOFA-2独占比例: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (
        SELECT stay_id FROM sofa2_sepsis_unique EXCEPT SELECT stay_id FROM sofa1_sepsis_unique
    ) only_sofa2) /
    (SELECT COUNT(*)::numeric FROM sofa2_sepsis_unique) * 100, 1
)::text || '%' as sofa2_only_pct

UNION ALL
SELECT 'SOFA-1向SOFA-2转换率: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM sofa1_sepsis_unique) /
    (SELECT COUNT(*)::numeric FROM sofa1_sepsis_unique) * 100, 1
)::text || '%' as conversion_rate;

-- 5. 验证数据质量
SELECT '=== 数据质量验证 ===' as section
UNION ALL
SELECT '总ICU住院数: ' || COUNT(DISTINCT stay_id)::text FROM mimiciv_derived.first_day_sofa

UNION ALL
SELECT '有SOFA-1评分的ICU数: ' || COUNT(DISTINCT stay_id)::text FROM mimiciv_derived.first_day_sofa WHERE sofa IS NOT NULL

UNION ALL
SELECT '有SOFA-2评分的ICU数: ' || COUNT(DISTINCT stay_id)::text FROM mimiciv_derived.first_day_sofa2 WHERE sofa2 IS NOT NULL

UNION ALL
SELECT '有可疑感染的ICU数: ' || COUNT(DISTINCT stay_id)::text FROM mimiciv_derived.suspicion_of_infection WHERE suspected_infection = 1;