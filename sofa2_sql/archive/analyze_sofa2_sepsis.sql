-- =================================================================
-- 基于SOFA-2的脓毒症统计分析
-- 分析SOFA-2版本脓毒症定义的特征和预测性能
-- =================================================================

-- 创建SOFA-2脓毒症患者的临时视图用于分析
CREATE TEMP VIEW sofa2_sepsis_analysis AS
SELECT
    subject_id,
    stay_id,
    sofa2_score,
    brain_24hours,
    respiratory_24hours,
    cardiovascular_24hours,
    liver_24hours,
    kidney_24hours,
    hemostasis_24hours,
    sepsis3_sofa2
FROM (
    -- 基于SOFA-2的脓毒症定义查询
    WITH sofa2 AS (
        SELECT
            stay_id,
            window_start_time AS starttime,
            window_end_time AS endtime,
            brain AS brain_24hours,
            respiratory AS respiratory_24hours,
            cardiovascular AS cardiovascular_24hours,
            liver AS liver_24hours,
            kidney AS kidney_24hours,
            hemostasis AS hemostasis_24hours,
            sofa2 AS sofa2_score
        FROM mimiciv_derived.first_day_sofa2
        WHERE sofa2 >= 2
    )

    SELECT
        soi.subject_id,
        soi.stay_id,
        s2.sofa2_score,
        s2.brain_24hours,
        s2.respiratory_24hours,
        s2.cardiovascular_24hours,
        s2.liver_24hours,
        s2.kidney_24hours,
        s2.hemostasis_24hours,
        s2.sofa2_score >= 2 AND soi.suspected_infection = 1 AS sepsis3_sofa2
    FROM mimiciv_derived.suspicion_of_infection AS soi
    INNER JOIN sofa2 AS s2
        ON soi.stay_id = s2.stay_id
            AND s2.endtime >= (soi.suspected_infection_time - INTERVAL '48 hours')
            AND s2.endtime <= (soi.suspected_infection_time + INTERVAL '24 hours')
    WHERE soi.stay_id IS NOT NULL
    GROUP BY
        soi.subject_id, soi.stay_id, s2.sofa2_score,
        s2.brain_24hours, s2.respiratory_24hours, s2.cardiovascular_24hours,
        s2.liver_24hours, s2.kidney_24hours, s2.hemostasis_24hours,
        s2.sofa2_score >= 2 AND soi.suspected_infection = 1
) AS sofa2_sepsis_subq;

-- 1. 基本统计信息
SELECT '=== SOFA-2脓毒症基本统计 ===' as analysis_section
UNION ALL
SELECT
    '总患者数: ' || COUNT(*) || '名' as total_patients
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '脓毒症患者: ' || SUM(CASE WHEN sepsis3_sofa2 = true THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sepsis3_sofa2 = true THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 1) || '%)' as sepsis_patients
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '非脓毒症患者: ' || SUM(CASE WHEN sepsis3_sofa2 = false THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sepsis3_sofa2 = false THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 1) || '%)' as non_sepsis_patients
FROM sofa2_sepsis_analysis;

-- 2. SOFA-2评分分布分析
SELECT '=== SOFA-2评分分布 ===' as distribution_section
UNION ALL
SELECT
    'SOFA-2评分均值: ' || ROUND(AVG(sofa2_score), 2) ||
    ', 中位数: ' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_score), 2) ||
    ', 范围: ' || MIN(sofa2_score) || '-' || MAX(sofa2_score) as score_stats
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '脓毒症患者SOFA-2: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = true THEN sofa2_score END), 2) ||
    ', 非脓毒症患者: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = false THEN sofa2_score END), 2) as group_comparison
FROM sofa2_sepsis_analysis;

-- 3. 器官系统评分分析
SELECT '=== 器官系统评分分析 (均值) ===' as organ_system_section
UNION ALL
SELECT
    '脑神经系统: ' || ROUND(AVG(brain_24hours), 2) as brain_system
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '呼吸系统: ' || ROUND(AVG(respiratory_24hours), 2) as resp_system
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '心血管系统: ' || ROUND(AVG(cardiovascular_24hours), 2) as cardio_system
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '肝脏系统: ' || ROUND(AVG(liver_24hours), 2) as liver_system
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '肾脏系统: ' || ROUND(AVG(kidney_24hours), 2) as kidney_system
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '凝血系统: ' || ROUND(AVG(hemostasis_24hours), 2) as hemostasis_system
FROM sofa2_sepsis_analysis;

-- 4. 脓毒症 vs 非脓毒症患者的器官系统对比
SELECT '=== 脓毒症 vs 非脓毒症 器官系统对比 ===' as organ_comparison_section
UNION ALL
SELECT
    '脑神经系统 - 脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = true THEN brain_24hours END), 2) ||
    ', 非脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = false THEN brain_24hours END), 2) as brain_comparison
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '呼吸系统 - 脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = true THEN respiratory_24hours END), 2) ||
    ', 非脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = false THEN respiratory_24hours END), 2) as resp_comparison
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '心血管系统 - 脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = true THEN cardiovascular_24hours END), 2) ||
    ', 非脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = false THEN cardiovascular_24hours END), 2) as cardio_comparison
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '肾脏系统 - 脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = true THEN kidney_24hours END), 2) ||
    ', 非脓毒症: ' || ROUND(AVG(CASE WHEN sepsis3_sofa2 = false THEN kidney_24hours END), 2) as kidney_comparison
FROM sofa2_sepsis_analysis;

-- 5. SOFA-2评分严重程度分布
SELECT '=== SOFA-2评分严重程度分布 ===' as severity_section
UNION ALL
SELECT
    '轻度 (2-5分): ' || SUM(CASE WHEN sofa2_score BETWEEN 2 AND 5 THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score BETWEEN 2 AND 5 THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 1) || '%)' as mild_severity
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '中度 (6-10分): ' || SUM(CASE WHEN sofa2_score BETWEEN 6 AND 10 THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score BETWEEN 6 AND 10 THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 1) || '%)' as moderate_severity
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '重度 (11-15分): ' || SUM(CASE WHEN sofa2_score BETWEEN 11 AND 15 THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score BETWEEN 11 AND 15 THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 1) || '%)' as severe_severity
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '极重度 (>15分): ' || SUM(CASE WHEN sofa2_score > 15 THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score > 15 THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 1) || '%)' as critical_severity
FROM sofa2_sepsis_analysis;

-- 6. 脓毒症患者的严重程度分布
SELECT '=== 脓毒症患者严重程度分布 ===' as sepsis_severity_section
UNION ALL
SELECT
    '脓毒症轻度 (2-5分): ' || SUM(CASE WHEN sofa2_score BETWEEN 2 AND 5 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score BETWEEN 2 AND 5 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END)::numeric /
                 SUM(CASE WHEN sepsis3_sofa2 = true THEN 1 ELSE 0 END) * 100, 1) || '%)' as sepsis_mild
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '脓毒症中度 (6-10分): ' || SUM(CASE WHEN sofa2_score BETWEEN 6 AND 10 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score BETWEEN 6 AND 10 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END)::numeric /
                 SUM(CASE WHEN sepsis3_sofa2 = true THEN 1 ELSE 0 END) * 100, 1) || '%)' as sepsis_moderate
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '脓毒症重度 (11-15分): ' || SUM(CASE WHEN sofa2_score BETWEEN 11 AND 15 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score BETWEEN 11 AND 15 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END)::numeric /
                 SUM(CASE WHEN sepsis3_sofa2 = true THEN 1 ELSE 0 END) * 100, 1) || '%)' as sepsis_severe
FROM sofa2_sepsis_analysis
UNION ALL
SELECT
    '脓毒症极重度 (>15分): ' || SUM(CASE WHEN sofa2_score > 15 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END) ||
    '名 (' || ROUND(SUM(CASE WHEN sofa2_score > 15 AND sepsis3_sofa2 = true THEN 1 ELSE 0 END)::numeric /
                 SUM(CASE WHEN sepsis3_sofa2 = true THEN 1 ELSE 0 END) * 100, 1) || '%)' as sepsis_critical
FROM sofa2_sepsis_analysis;

-- 清理临时视图
DROP VIEW IF EXISTS sofa2_sepsis_analysis;