-- =================================================================
-- SOFA-1 vs SOFA-2脓毒症患者简洁对比分析
-- =================================================================

-- 基本统计对比
SELECT '=== 基本统计对比 ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者数: ' || COUNT(*)::text FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
WHERE fds.sofa_score >= 2 AND soi.suspected_infection = 1
    AND fds.endtime >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds.endtime <= (soi.suspected_infection_time + INTERVAL '24 hours')

UNION ALL
SELECT 'SOFA-2脓毒症患者数: ' || COUNT(*)::text FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.window_end_time >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds2.window_end_time <= (soi.suspected_infection_time + INTERVAL '24 hours');

-- 死亡率对比
SELECT '=== 死亡率对比 ===' as section
UNION ALL
SELECT 'SOFA-1 ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
WHERE fds.sofa_score >= 2 AND soi.suspected_infection = 1
    AND fds.endtime >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds.endtime <= (soi.suspected_infection_time + INTERVAL '24 hours')

UNION ALL
SELECT 'SOFA-2 ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.window_end_time >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds2.window_end_time <= (soi.suspected_infection_time + INTERVAL '24 hours');

-- SOFA评分对比
SELECT '=== SOFA评分对比 ===' as section
UNION ALL
SELECT 'SOFA-1平均评分: ' || ROUND(AVG(fds.sofa_score), 2)::text FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
WHERE fds.sofa_score >= 2 AND soi.suspected_infection = 1
    AND fds.endtime >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds.endtime <= (soi.suspected_infection_time + INTERVAL '24 hours')

UNION ALL
SELECT 'SOFA-2平均评分: ' || ROUND(AVG(fds2.sofa2), 2)::text FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
    AND fds2.window_end_time >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds2.window_end_time <= (soi.suspected_infection_time + INTERVAL '24 hours');

-- 重叠分析
WITH sofa1_sepsis AS (
    SELECT stay_id FROM mimiciv_derived.first_day_sofa fds
    JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
    WHERE fds.sofa_score >= 2 AND soi.suspected_infection = 1
        AND fds.endtime >= (soi.suspected_infection_time - INTERVAL '48 hours')
        AND fds.endtime <= (soi.suspected_infection_time + INTERVAL '24 hours')
),
sofa2_sepsis AS (
    SELECT stay_id FROM mimiciv_derived.first_day_sofa2 fds2
    JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
    WHERE fds2.sofa2 >= 2 AND soi.suspected_infection = 1
        AND fds2.window_end_time >= (soi.suspected_infection_time - INTERVAL '48 hours')
        AND fds2.window_end_time <= (soi.suspected_infection_time + INTERVAL '24 hours')
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
) only_sofa2;