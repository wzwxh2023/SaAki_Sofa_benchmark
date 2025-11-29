-- =================================================================
-- SOFA-1 vs SOFA-2脓毒症患者对比分析 (修复版)
-- =================================================================

-- 1. 基本统计对比
SELECT '=== 基本统计对比 ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者数: ' || COUNT(*)::text FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
WHERE fds.sofa >= 2 AND soi.suspected_infection = 1
    AND soi.stay_id IS NOT NULL

UNION ALL
SELECT 'SOFA-2脓毒症患者数: ' || COUNT(*)::text FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND soi.stay_id IS NOT NULL;

-- 2. 死亡率对比 (需要join到icustays表获取死亡率信息)
SELECT '=== 死亡率对比 ===' as section
UNION ALL
SELECT 'SOFA-1 ICU死亡率: ' || ROUND(AVG(CASE WHEN ic.expire_flag = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%'
FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
JOIN mimiciv_icu.icustays ic ON fds.stay_id = ic.stay_id
WHERE fds.sofa >= 2 AND soi.suspected_infection = 1 AND ic.stay_id IS NOT NULL

UNION ALL
SELECT 'SOFA-2 ICU死亡率: ' || ROUND(AVG(CASE WHEN ic.expire_flag = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%'
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
JOIN mimiciv_icu.icustays ic ON fds2.stay_id = ic.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1 AND ic.stay_id IS NOT NULL;

-- 3. SOFA评分对比
SELECT '=== SOFA评分对比 ===' as section
UNION ALL
SELECT 'SOFA-1平均评分: ' || ROUND(AVG(fds.sofa), 2)::text FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
WHERE fds.sofa >= 2 AND soi.suspected_infection = 1 AND fds.stay_id IS NOT NULL

UNION ALL
SELECT 'SOFA-2平均评分: ' || ROUND(AVG(fds2.sofa2), 2)::text FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1 AND fds2.stay_id IS NOT NULL;

-- 4. 重叠分析
WITH sofa1_sepsis AS (
    SELECT fds.stay_id FROM mimiciv_derived.first_day_sofa fds
    JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
    WHERE fds.sofa >= 2 AND soi.suspected_infection = 1 AND fds.stay_id IS NOT NULL
),
sofa2_sepsis AS (
    SELECT fds2.stay_id FROM mimiciv_derived.first_day_sofa2 fds2
    JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
    WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1 AND fds2.stay_id IS NOT NULL
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
SELECT 'SOFA-1独占患者比例: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (SELECT stay_id FROM sofa1_sepsis EXCEPT SELECT stay_id FROM sofa2_sepsis) only_sofa1) /
    (SELECT COUNT(*)::numeric FROM sofa1_sepsis) * 100, 1
)::text || '%' as sofa1_only_pct

UNION ALL
SELECT 'SOFA-2独占患者比例: ' || ROUND(
    (SELECT COUNT(*)::numeric FROM (SELECT stay_id FROM sofa2_sepsis EXCEPT SELECT stay_id FROM sofa1_sepsis) only_sofa2) /
    (SELECT COUNT(*)::numeric FROM sofa2_sepsis) * 100, 1
)::text || '%' as sofa2_only_pct;