-- =================================================================
-- SOFA-1 vs SOFA-2脓毒症患者对比分析
-- 比较基于不同SOFA评分定义的脓毒症患者特征和结果
-- =================================================================

-- 创建基于SOFA-1的脓毒症患者视图
CREATE TEMP VIEW sofa1_sepsis AS
SELECT
    subject_id,
    stay_id,
    'SOFA-1' as sofa_type,
    sofa_score,
    respiration_24hours,
    coagulation_24hours,
    liver_24hours,
    cardiovascular_24hours,
    cns_24hours,
    renal_24hours,
    1 as sepsis_status,
    icu_mortality,
    hospital_expire_flag,
    icu_los_hours,
    age,
    gender,
    race,
    admission_type,
    severity_category
FROM mimiciv_derived.first_day_sofa fds
JOIN mimiciv_derived.suspicion_of_infection soi ON fds.stay_id = soi.stay_id
WHERE fds.sofa_score >= 2
    AND soi.suspected_infection = 1
    AND fds.endtime >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds.endtime <= (soi.suspected_infection_time + INTERVAL '24 hours');

-- 创建基于SOFA-2的脓毒症患者视图
CREATE TEMP VIEW sofa2_sepsis AS
SELECT
    subject_id,
    stay_id,
    'SOFA-2' as sofa_type,
    sofa2 as sofa_score,
    respiratory_24hours,
    hemostasis_24hours as coagulation_24hours,
    liver_24hours,
    cardiovascular_24hours,
    brain_24hours as cns_24hours,
    kidney_24hours,
    1 as sepsis_status,
    icu_mortality,
    hospital_expire_flag,
    icu_los_hours,
    age,
    gender,
    race,
    admission_type,
    severity_category
FROM mimiciv_derived.first_day_sofa2 fds2
JOIN mimiciv_derived.suspicion_of_infection soi ON fds2.stay_id = soi.stay_id
WHERE fds2.sofa2 >= 2
    AND soi.suspected_infection = 1
    AND fds2.window_end_time >= (soi.suspected_infection_time - INTERVAL '48 hours')
    AND fds2.window_end_time <= (soi.suspected_infection_time + INTERVAL '24 hours');

-- 1. 基本统计对比
SELECT '=== SOFA-1 vs SOFA-2 脓毒症患者基本对比 ===' as comparison_section
UNION ALL
SELECT
    'SOFA-1脓毒症患者: ' || COUNT(*)::text || '名' as sofa1_patients
FROM sofa1_sepsis
UNION ALL
SELECT
    'SOFA-2脓毒症患者: ' || COUNT(*)::text || '名' as sofa2_patients
FROM sofa2_sepsis
UNION ALL
SELECT
    '重叠患者数: ' ||
    (SELECT COUNT(*) FROM
     (SELECT stay_id FROM sofa1_sepsis INTERSECT SELECT stay_id FROM sofa2_sepsis) overlap)::text || '名' as overlap_patients
UNION ALL
SELECT
    '仅SOFA-1脓毒症: ' ||
    (SELECT COUNT(*) FROM
     (SELECT stay_id FROM sofa1_sepsis EXCEPT SELECT stay_id FROM sofa2_sepsis) only_sofa1)::text || '名' as only_sofa1_patients
UNION ALL
SELECT
    '仅SOFA-2脓毒症: ' ||
    (SELECT COUNT(*) FROM
     (SELECT stay_id FROM sofa2_sepsis EXCEPT SELECT stay_id FROM sofa1_sepsis) only_sofa2)::text || '名' as only_sofa2_patients;

-- 2. 死亡率对比
SELECT '=== 死亡率对比 ===' as mortality_section
UNION ALL
SELECT
    'SOFA-1 ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' as sofa1_icu_mortality
FROM sofa1_sepsis
UNION ALL
SELECT
    'SOFA-2 ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' as sofa2_icu_mortality
FROM sofa2_sepsis
UNION ALL
SELECT
    'SOFA-1 住院死亡率: ' || ROUND(AVG(CASE WHEN hospital_expire_flag = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' as sofa1_hospital_mortality
FROM sofa1_sepsis
UNION ALL
SELECT
    'SOFA-2 住院死亡率: ' || ROUND(AVG(CASE WHEN hospital_expire_flag = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' as sofa2_hospital_mortality
FROM sofa2_sepsis;

-- 3. SOFA评分分布对比
SELECT '=== SOFA评分分布对比 ===' as score_distribution
UNION ALL
SELECT
    'SOFA-1平均评分: ' || ROUND(AVG(sofa_score), 2)::text ||
    ', 中位数: ' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_score), 2)::text as sofa1_stats
FROM sofa1_sepsis
UNION ALL
SELECT
    'SOFA-2平均评分: ' || ROUND(AVG(sofa_score), 2)::text ||
    ', 中位数: ' || ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_score), 2)::text as sofa2_stats
FROM sofa2_sepsis
UNION ALL
SELECT
    'SOFA-1评分范围: ' || MIN(sofa_score)::text || '-' || MAX(sofa_score)::text as sofa1_range
FROM sofa1_sepsis
UNION ALL
SELECT
    'SOFA-2评分范围: ' || MIN(sofa_score)::text || '-' || MAX(sofa_score)::text as sofa2_range
FROM sofa2_sepsis;

-- 4. 器官系统评分对比
SELECT '=== 器官系统评分对比 (平均值) ===' as organ_comparison
UNION ALL
SELECT
    '呼吸系统 - SOFA-1: ' || ROUND(AVG(respiration_24hours), 2)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(respiratory_24hours), 2)::text FROM sofa2_sepsis) as respiratory_comparison
FROM sofa1_sepsis
UNION ALL
SELECT
    '凝血系统 - SOFA-1: ' || ROUND(AVG(coagulation_24hours), 2)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(coagulation_24hours), 2)::text FROM sofa2_sepsis) as coagulation_comparison
FROM sofa1_sepsis
UNION ALL
SELECT
    '肝脏系统 - SOFA-1: ' || ROUND(AVG(liver_24hours), 2)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(liver_24hours), 2)::text FROM sofa2_sepsis) as liver_comparison
FROM sofa1_sepsis
UNION ALL
SELECT
    '心血管系统 - SOFA-1: ' || ROUND(AVG(cardiovascular_24hours), 2)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(cardiovascular_24hours), 2)::text FROM sofa2_sepsis) as cardiovascular_comparison
FROM sofa1_sepsis
UNION ALL
SELECT
    '神经系统 - SOFA-1: ' || ROUND(AVG(cns_24hours), 2)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(cns_24hours), 2)::text FROM sofa2_sepsis) as cns_comparison
FROM sofa1_sepsis
UNION ALL
SELECT
    '肾脏系统 - SOFA-1: ' || ROUND(AVG(renal_24hours), 2)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(kidney_24hours), 2)::text FROM sofa2_sepsis) as renal_comparison
FROM sofa1_sepsis;

-- 5. 患者特征对比
SELECT '=== 患者特征对比 ===' as patient_characteristics
UNION ALL
SELECT
    '年龄 - SOFA-1: ' || ROUND(AVG(age), 1)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(age), 1)::text FROM sofa2_sepsis) as age_comparison
FROM sofa1_sepsis
UNION ALL
SELECT
    'ICU住院时长(小时) - SOFA-1: ' || ROUND(AVG(icu_los_hours), 1)::text ||
    ', SOFA-2: ' || (SELECT ROUND(AVG(icu_los_hours), 1)::text FROM sofa2_sepsis) as los_comparison
FROM sofa1_sepsis
UNION ALL
SELECT
    '男性比例 - SOFA-1: ' || ROUND(AVG(CASE WHEN gender = 'M' THEN 1 ELSE 0 END) * 100, 1)::text ||
    '%, SOFA-2: ' || (SELECT ROUND(AVG(CASE WHEN gender = 'M' THEN 1 ELSE 0 END) * 100, 1)::text || '%' FROM sofa2_sepsis) as gender_comparison
FROM sofa1_sepsis;

-- 6. 重叠患者的详细分析
SELECT '=== 重叠患者分析 (同时被两种方法诊断为脓毒症) ===' as overlap_analysis
UNION ALL
SELECT
    '重叠患者数: ' || COUNT(*)::text || '名' as overlap_count
FROM (
    SELECT stay_id FROM sofa1_sepsis INTERSECT SELECT stay_id FROM sofa2_sepsis
) overlap_stays
JOIN sofa1_sepsis s1 ON overlap_stays.stay_id = s1.stay_id
UNION ALL
SELECT
    '重叠患者ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' as overlap_icu_mortality
FROM (
    SELECT stay_id FROM sofa1_sepsis INTERSECT SELECT stay_id FROM sofa2_sepsis
) overlap_stays
JOIN sofa1_sepsis s1 ON overlap_stays.stay_id = s1.stay_id
UNION ALL
SELECT
    '重叠患者平均SOFA-1评分: ' || ROUND(AVG(s1.sofa_score), 2)::text ||
    ', SOFA-2评分: ' || ROUND(AVG(s2.sofa_score), 2)::text as overlap_scores
FROM (
    SELECT stay_id FROM sofa1_sepsis INTERSECT SELECT stay_id FROM sofa2_sepsis
) overlap_stays
JOIN sofa1_sepsis s1 ON overlap_stays.stay_id = s1.stay_id
JOIN sofa2_sepsis s2 ON overlap_stays.stay_id = s2.stay_id;

-- 7. 仅SOFA-1患者特征
SELECT '=== 仅SOFA-1脓毒症患者特征 ===' as only_sofa1_analysis
UNION ALL
SELECT
    '仅SOFA-1患者数: ' || COUNT(*)::text || '名' as only_sofa1_count
FROM (
    SELECT stay_id FROM sofa1_sepsis EXCEPT SELECT stay_id FROM sofa2_sepsis
) only_sofa1_stays
JOIN sofa1_sepsis s1 ON only_sofa1_stays.stay_id = s1.stay_id
UNION ALL
SELECT
    '仅SOFA-1患者ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' as only_sofa1_mortality
FROM (
    SELECT stay_id FROM sofa1_sepsis EXCEPT SELECT stay_id FROM sofa2_sepsis
) only_sofa1_stays
JOIN sofa1_sepsis s1 ON only_sofa1_stays.stay_id = s1.stay_id
UNION ALL
SELECT
    '仅SOFA-1患者平均SOFA-1评分: ' || ROUND(AVG(sofa_score), 2)::text as only_sofa1_score
FROM (
    SELECT stay_id FROM sofa1_sepsis EXCEPT SELECT stay_id FROM sofa2_sepsis
) only_sofa1_stays
JOIN sofa1_sepsis s1 ON only_sofa1_stays.stay_id = s1.stay_id;

-- 8. 仅SOFA-2患者特征
SELECT '=== 仅SOFA-2脓毒症患者特征 ===' as only_sofa2_analysis
UNION ALL
SELECT
    '仅SOFA-2患者数: ' || COUNT(*)::text || '名' as only_sofa2_count
FROM (
    SELECT stay_id FROM sofa2_sepsis EXCEPT SELECT stay_id FROM sofa1_sepsis
) only_sofa2_stays
JOIN sofa2_sepsis s2 ON only_sofa2_stays.stay_id = s2.stay_id
UNION ALL
SELECT
    '仅SOFA-2患者ICU死亡率: ' || ROUND(AVG(CASE WHEN icu_mortality = 1 THEN 1 ELSE 0 END) * 100, 1)::text || '%' as only_sofa2_mortality
FROM (
    SELECT stay_id FROM sofa2_sepsis EXCEPT SELECT stay_id FROM sofa1_sepsis
) only_sofa2_stays
JOIN sofa2_sepsis s2 ON only_sofa2_stays.stay_id = s2.stay_id
UNION ALL
SELECT
    '仅SOFA-2患者平均SOFA-2评分: ' || ROUND(AVG(sofa_score), 2)::text as only_sofa2_score
FROM (
    SELECT stay_id FROM sofa2_sepsis EXCEPT SELECT stay_id FROM sofa1_sepsis
) only_sofa2_stays
JOIN sofa2_sepsis s2 ON only_sofa2_stays.stay_id = s2.stay_id;

-- 清理临时视图
DROP VIEW IF EXISTS sofa1_sepsis;
DROP VIEW IF EXISTS sofa2_sepsis;