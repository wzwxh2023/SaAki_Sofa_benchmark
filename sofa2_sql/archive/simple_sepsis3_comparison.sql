-- =================================================================
-- SOFA-1 vs SOFA-2脓毒症患者对比分析 (简化版，使用官方sepsis3表)
-- =================================================================

-- 1. 基本统计对比
SELECT '=== 基本统计对比 ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者数 (官方sepsis3): ' || COUNT(DISTINCT stay_id)::text
FROM mimiciv_derived.sepsis3
WHERE sepsis3 = true

UNION ALL
SELECT 'SOFA-2脓毒症患者数 (简单定义): ' || COUNT(DISTINCT fds2.stay_id)::text
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.stay_id IS NOT NULL;

-- 2. 官方sepsis3表的详细统计
SELECT '=== 官方SOFA-1脓毒症统计 ===' as section
UNION ALL
SELECT '官方sepsis3表脓毒症患者数: ' || COUNT(DISTINCT stay_id)::text
FROM mimiciv_derived.sepsis3
WHERE sepsis3 = true

UNION ALL
SELECT '官方SOFA-1平均评分: ' || ROUND(AVG(sofa_score), 2)::text
FROM mimiciv_derived.sepsis3
WHERE sepsis3 = true AND sofa_score IS NOT NULL

UNION ALL
SELECT '官方SOFA-1评分范围: ' || MIN(sofa_score)::text || '-' || MAX(sofa_score)::text
FROM mimiciv_derived.sepsis3
WHERE sepsis3 = true AND sofa_score IS NOT NULL

UNION ALL
SELECT '官方SOFA-1评分中位数: ' || ROUND(MEDIAN(sofa_score), 1)::text
FROM mimiciv_derived.sepsis3
WHERE sepsis3 = true AND sofa_score IS NOT NULL;

-- 3. SOFA-2的详细统计 (简单方法)
SELECT '=== SOFA-2脓毒症统计 ===' as section
UNION ALL
SELECT 'SOFA-2脓毒症患者数: ' || COUNT(DISTINCT stay_id)::text
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.stay_id IS NOT NULL

UNION ALL
SELECT 'SOFA-2平均评分: ' || ROUND(AVG(fds2.sofa2), 2)::text
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.stay_id IS NOT NULL

UNION ALL
SELECT 'SOFA-2评分范围: ' || MIN(fds2.sofa2)::text || '-' || MAX(fds2.sofa2)::text
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.stay_id IS NOT NULL

UNION ALL
SELECT 'SOFA-2评分中位数: ' || ROUND(MEDIAN(fds2.sofa2), 1)::text
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.stay_id IS NOT NULL;

-- 4. 重叠分析
WITH sofa1_sepsis AS (
    SELECT stay_id FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true
),
sofa2_sepsis AS (
    SELECT DISTINCT fds2.stay_id
    FROM mimiciv_derived.first_day_sofa2 fds2
    JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
    WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
        AND fds2.stay_id IS NOT NULL
)

SELECT '=== 重叠分析 ===' as section
UNION ALL
SELECT '重叠患者数: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM sofa1_sepsis INTERSECT SELECT stay_id FROM sofa2_sepsis
) overlap

UNION ALL
SELECT '仅SOFA-1脓毒症: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM sofa1_sepsis EXCEPT SELECT stay_id FROM sofa2_sepsis
) only_sofa1

UNION ALL
SELECT '仅SOFA-2脓毒症: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM sofa2_sepsis EXCEPT SELECT stay_id FROM sofa1_sepsis
) only_sofa2

UNION ALL
SELECT '重叠比例 (相对于SOFA-1): ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (
        SELECT stay_id FROM sofa1_sepsis INTERSECT SELECT stay_id FROM sofa2_sepsis
    ) overlap) /
    (SELECT COUNT(*)::numeric FROM sofa1_sepsis) * 100, 1
)::text || '%'

UNION ALL
SELECT 'SOFA-2额外识别率: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (
        SELECT stay_id FROM sofa2_sepsis EXCEPT SELECT stay_id FROM sofa1_sepsis
    ) only_sofa2) /
    (SELECT COUNT(*)::numeric FROM sofa1_sepsis) * 100, 1
)::text || '%';

-- 5. 数据质量验证
SELECT '=== 数据质量验证 ===' as section
UNION ALL
SELECT '官方sepsis3表总记录数: ' || COUNT(*)::text
FROM mimiciv_derived.sepsis3
UNION ALL
SELECT '官方sepsis3表脓毒症患者数: ' || COUNT(*)::text
FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true
UNION ALL
SELECT 'SOFA-2表总记录数: ' || COUNT(*)::text
FROM mimiciv_derived.first_day_sofa2
UNION ALL
SELECT 'SOFA-2有效评分记录数: ' || COUNT(*)::text
FROM mimiciv_derived.first_day_sofa2 WHERE sofa2 IS NOT NULL
UNION ALL
SELECT 'suspicion_of_infection表总记录数: ' || COUNT(*)::text
FROM mimiciv_derived.suspicion_of_infection
UNION ALL
SELECT 'suspicion_of_infection表唯一stay数: ' || COUNT(DISTINCT stay_id)::text
FROM mimiciv_derived.suspicion_of_infection;