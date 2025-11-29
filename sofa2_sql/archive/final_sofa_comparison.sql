-- =================================================================
-- SOFA-1 vs SOFA-2脓毒症患者最终对比分析 (简化准确版)
-- 基于修复重复计数问题的准确统计
-- =================================================================

-- 确认基本数据范围
SELECT '=== 数据基础统计 ===' as section
UNION ALL
SELECT '总ICU住院数: ' || COUNT(DISTINCT stay_id)::text || ' (SOFA-1)' FROM mimiciv_derived.first_day_sofa
UNION ALL
SELECT '总ICU住院数: ' || COUNT(DISTINCT stay_id)::text || ' (SOFA-2)' FROM mimiciv_derived.first_day_sofa2
UNION ALL
SELECT '有可疑感染的ICU数: ' || COUNT(DISTINCT stay_id)::text FROM mimiciv_derived.suspicion_of_infection WHERE suspected_infection = 1;

-- 使用最简单的方法计算脓毒症患者数
SELECT '=== 脓毒症患者数量对比 ===' as section
UNION ALL
SELECT 'SOFA-1脓毒症患者 (简化方法): ' || COUNT(DISTINCT stay_id)::text
FROM mimiciv_derived.first_day_sofa fds
WHERE EXISTS (
    SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
    WHERE soi.stay_id = fds.stay_id AND soi.suspected_infection = 1
)
AND fds.sofa >= 2

UNION ALL
SELECT 'SOFA-2脓毒症患者 (简化方法): ' || COUNT(DISTINCT stay_id)::text
FROM mimiciv_derived.first_day_sofa2 fds2
WHERE EXISTS (
    SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
    WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
)
AND fds2.sofa2 >= 2

UNION ALL
SELECT '同时满足两者的ICU数: ' || COUNT(DISTINCT fds.stay_id)::text
FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.first_day_sofa2 fds2 ON fds.stay_id = fds2.stay_id
WHERE EXISTS (
    SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
    WHERE soi.stay_id = fds.stay_id AND soi.suspected_infection = 1
)
AND fds.sofa >= 2 AND fds2.sofa2 >= 2

UNION ALL
SELECT '仅SOFA-1脓毒症ICU数: ' || COUNT(DISTINCT fds.stay_id)::text
FROM mimiciv_derived.first_day_sofa fds
WHERE EXISTS (
    SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
    WHERE soi.stay_id = fds.stay_id AND soi.suspected_infection = 1
)
AND fds.sofa >= 2
AND NOT EXISTS (
    SELECT 1 FROM mimiciv_derived.first_day_sofa2 fds2
    WHERE fds2.stay_id = fds.stay_id AND fds2.sofa2 >= 2
)

UNION ALL
SELECT '仅SOFA-2脓毒症ICU数: ' || COUNT(DISTINCT fds2.stay_id)::text
FROM mimiciv_derived.first_day_sofa2 fds2
WHERE EXISTS (
    SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
    WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
)
AND fds2.sofa2 >= 2
AND NOT EXISTS (
    SELECT 1 FROM mimiciv_derived.first_day_sofa fds
    WHERE fds.stay_id = fds2.stay_id AND fds.sofa >= 2
);

-- 计算比例
SELECT '=== 比例分析 ===' as section
UNION ALL
SELECT '重叠率 (相对于SOFA-1): ' || ROUND(
    (SELECT COUNT(DISTINCT fds.stay_id) FROM mimiciv_derived.first_day_sofa fds
     JOIN mimiciv_derived.first_day_sofa2 fds2 ON fds.stay_id = fds2.stay_id
     WHERE EXISTS (SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
                   WHERE soi.stay_id = fds.stay_id AND soi.suspected_infection = 1)
     AND fds.sofa >= 2 AND fds2.sofa2 >= 2) * 100.0 /
    (SELECT COUNT(DISTINCT fds.stay_id) FROM mimiciv_derived.first_day_sofa fds
     WHERE EXISTS (SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
                   WHERE soi.stay_id = fds.stay_id AND soi.suspected_infection = 1)
     AND fds.sofa >= 2), 1)::text || '%'

UNION ALL
SELECT 'SOFA-2额外识别率: ' || ROUND(
    ((SELECT COUNT(DISTINCT fds2.stay_id) FROM mimiciv_derived.first_day_sofa2 fds2
      WHERE EXISTS (SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
                    WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1)
      AND fds2.sofa2 >= 2) -
     (SELECT COUNT(DISTINCT fds.stay_id) FROM mimiciv_derived.first_day_sofa fds
      WHERE EXISTS (SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
                    WHERE soi.stay_id = fds.stay_id AND soi.suspected_infection = 1)
      AND fds.sofa >= 2)) * 100.0 /
    (SELECT COUNT(DISTINCT fds.stay_id) FROM mimiciv_derived.first_day_sofa fds
     WHERE EXISTS (SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
                   WHERE soi.stay_id = fds.stay_id AND soi.suspected_infection = 1)
     AND fds.sofa >= 2), 1)::text || '%';