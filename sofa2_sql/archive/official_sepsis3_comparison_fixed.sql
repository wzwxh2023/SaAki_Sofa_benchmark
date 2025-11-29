-- =================================================================
-- SOFA-1 vs SOFA-2脓毒症患者对比分析 (使用官方sepsis3表) - 修复版
-- 使用mimiciv_derived.sepsis3作为SOFA-1脓毒症的金标准
-- =================================================================

-- 1. 基本统计对比
SELECT '=== 基本统计对比 (使用官方sepsis3表) ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者数 (官方sepsis3): ' || COUNT(DISTINCT s3.stay_id)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true

UNION ALL
SELECT 'SOFA-2脓毒症患者数 (自定义计算): ' || COUNT(DISTINCT fds2.stay_id)::text
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.stay_id IS NOT NULL;

-- 2. 使用更准确的SOFA-2脓毒症定义 (与sepsis3表一致的时间窗口)
WITH sofa2_sepsis AS (
    SELECT DISTINCT
        fds2.stay_id,
        fds2.sofa2,
        fds2.window_start_time,
        fds2.window_end_time,
        fds2.respiratory,
        fds2.cardiovascular,
        fds2.liver,
        fds2.kidney,
        fds2.brain,
        fds2.hemostasis
    FROM mimiciv_derived.first_day_sofa2 fds2
    JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
    WHERE fds2.sofa2 >= 2
        AND soi.suspected_infection = 1
        AND fds2.window_end_time >= (soi.suspected_infection_time - INTERVAL '48 hours')
        AND fds2.window_end_time <= (soi.suspected_infection_time + INTERVAL '24 hours')
        AND fds2.stay_id IS NOT NULL
)

SELECT '=== 准确的脓毒症统计 (时间窗口匹配) ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者数 (官方sepsis3): ' || COUNT(DISTINCT s3.stay_id)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true

UNION ALL
SELECT 'SOFA-2脓毒症患者数 (时间窗口匹配): ' || COUNT(DISTINCT s2.stay_id)::text
FROM sofa2_sepsis s2

UNION ALL
SELECT 'SOFA-1平均评分: ' || ROUND(AVG(s3.sofa_score), 2)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.sofa_score IS NOT NULL

UNION ALL
SELECT 'SOFA-2平均评分: ' || ROUND(AVG(s2.sofa2), 2)::text
FROM sofa2_sepsis s2;

-- 3. 重叠分析 (使用官方sepsis3表)
SELECT '=== 重叠分析 (官方sepsis3 vs SOFA-2) ===' as section
UNION ALL
SELECT '重叠患者数: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true
    INTERSECT
    SELECT stay_id FROM sofa2_sepsis
) overlap

UNION ALL
SELECT '仅SOFA-1脓毒症 (官方): ' || COUNT(*)::text FROM (
    SELECT stay_id FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true
    EXCEPT
    SELECT stay_id FROM sofa2_sepsis
) only_sofa1

UNION ALL
SELECT '仅SOFA-2脓毒症: ' || COUNT(*)::text FROM (
    SELECT stay_id FROM sofa2_sepsis
    EXCEPT
    SELECT stay_id FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true
) only_sofa2

UNION ALL
SELECT '重叠比例 (相对于SOFA-1): ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (
        SELECT stay_id FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true
        INTERSECT
        SELECT stay_id FROM sofa2_sepsis
    ) overlap) /
    (SELECT COUNT(*)::numeric FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true) * 100, 1
)::text || '%' as overlap_pct

UNION ALL
SELECT 'SOFA-2额外识别率: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (
        SELECT stay_id FROM sofa2_sepsis
        EXCEPT
        SELECT stay_id FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true
    ) only_sofa2) /
    (SELECT COUNT(*)::numeric FROM mimiciv_derived.sepsis3 WHERE sepsis3 = true) * 100, 1
)::text || '%' as additional_rate;

-- 4. 器官系统评分对比
SELECT '=== 器官系统评分对比 (平均值) ===' as section
UNION ALL
SELECT '呼吸系统 - SOFA-1: ' || ROUND(AVG(s3.respiration), 2)::text ||
       ', SOFA-2: ' || ROUND(AVG(s2.respiratory), 2)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.respiration IS NOT NULL
CROSS JOIN (SELECT AVG(respiratory) as respiratory FROM sofa2_sepsis) s2
UNION ALL
SELECT '心血管系统 - SOFA-1: ' || ROUND(AVG(s3.cardiovascular), 2)::text ||
       ', SOFA-2: ' || ROUND(AVG(s2.cardiovascular), 2)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.cardiovascular IS NOT NULL
CROSS JOIN (SELECT AVG(cardiovascular) as cardiovascular FROM sofa2_sepsis) s2
UNION ALL
SELECT '肝脏系统 - SOFA-1: ' || ROUND(AVG(s3.liver), 2)::text ||
       ', SOFA-2: ' || ROUND(AVG(s2.liver), 2)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.liver IS NOT NULL
CROSS JOIN (SELECT AVG(liver) as liver FROM sofa2_sepsis) s2
UNION ALL
SELECT '肾脏系统 - SOFA-1: ' || ROUND(AVG(s3.renal), 2)::text ||
       ', SOFA-2: ' || ROUND(AVG(s2.kidney), 2)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.renal IS NOT NULL
CROSS JOIN (SELECT AVG(kidney) as kidney FROM sofa2_sepsis) s2
UNION ALL
SELECT '神经系统 - SOFA-1: ' || ROUND(AVG(s3.cns), 2)::text ||
       ', SOFA-2: ' || ROUND(AVG(s2.brain), 2)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.cns IS NOT NULL
CROSS JOIN (SELECT AVG(brain) as brain FROM sofa2_sepsis) s2
UNION ALL
SELECT '凝血系统 - SOFA-1: ' || ROUND(AVG(s3.coagulation), 2)::text ||
       ', SOFA-2: ' || ROUND(AVG(s2.hemostasis), 2)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.coagulation IS NOT NULL
CROSS JOIN (SELECT AVG(hemostasis) as hemostasis FROM sofa2_sepsis) s2;

-- 5. 评分分布对比
SELECT '=== SOFA评分分布对比 ===' as section
UNION ALL
SELECT 'SOFA-1评分范围: ' || MIN(s3.sofa_score)::text || '-' || MAX(s3.sofa_score)::text ||
       ', 中位数: ' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s3.sofa_score), 1)::text
FROM mimiciv_derived.sepsis3 s3
WHERE s3.sepsis3 = true AND s3.sofa_score IS NOT NULL
UNION ALL
SELECT 'SOFA-2评分范围: ' || MIN(s2.sofa2)::text || '-' || MAX(s2.sofa2)::text ||
       ', 中位数: ' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s2.sofa2), 1)::text
FROM sofa2_sepsis s2;