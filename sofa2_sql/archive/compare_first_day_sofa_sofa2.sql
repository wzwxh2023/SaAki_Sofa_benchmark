-- =================================================================
-- SOFA vs SOFA2 首日评分对比分析脚本
-- 功能：系统对比first_day_sofa和first_day_sofa2的差异
-- 包括：总分对比、各组分对比、分布差异、统计指标
-- =================================================================

-- 设置性能参数
SET work_mem = '512MB';
SET maintenance_work_mem = '512MB';
SET max_parallel_workers = 8;
SET max_parallel_workers_per_gather = 4;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;

-- =================================================================
-- 创建对比分析主查询
-- =================================================================
WITH
-- 1. 基础数据连接和字段映射
base_comparison AS (
    SELECT
        s1.stay_id,
        s1.subject_id,
        s1.hadm_id,

        -- SOFA-1 评分 (原始标准)
        s1.respiration AS sofa_respiration,
        s1.coagulation AS sofa_coagulation,  -- 对应SOFA2的hemostasis
        s1.liver AS sofa_liver,
        s1.cardiovascular AS sofa_cardiovascular,
        s1.cns AS sofa_cns,  -- 对应SOFA2的brain
        s1.renal AS sofa_renal,
        s1.sofa AS sofa_total,

        -- SOFA-2 评分 (新标准)
        s2.respiratory AS sofa2_respiratory,
        s2.hemostasis AS sofa2_hemostasis,
        s2.liver AS sofa2_liver,
        s2.cardiovascular AS sofa2_cardiovascular,
        s2.brain AS sofa2_brain,
        s2.kidney AS sofa2_kidney,
        s2.sofa2 AS sofa2_total,

        -- 基础临床信息
        s2.age,
        s2.gender,
        s2.icu_mortality,
        s2.hospital_expire_flag,
        s2.icu_los_hours
    FROM mimiciv_derived.first_day_sofa s1
    INNER JOIN mimiciv_derived.first_day_sofa2 s2
        ON s1.stay_id = s2.stay_id
),

-- 2. 计算评分差异
score_differences AS (
    SELECT
        *,

        -- 总分差异
        (sofa2_total - sofa_total) AS total_diff,

        -- 各系统差异 (注意字段对应关系)
        (sofa2_respiratory - sofa_respiration) AS respiratory_diff,
        (sofa2_hemostasis - sofa_coagulation) AS hemostasis_coagulation_diff,  -- 新vs旧
        (sofa2_liver - sofa_liver) AS liver_diff,
        (sofa2_cardiovascular - sofa_cardiovascular) AS cardiovascular_diff,
        (sofa2_brain - sofa_cns) AS brain_cns_diff,  -- 新vs旧
        (sofa2_kidney - sofa_renal) AS kidney_renal_diff,  -- 新vs旧

        -- 差异分类
        CASE
            WHEN sofa2_total > sofa_total THEN 'Increased'
            WHEN sofa2_total < sofa_total THEN 'Decreased'
            ELSE 'Same'
        END AS change_category,

        -- 差异大小
        ABS(sofa2_total - sofa_total) AS absolute_diff
    FROM base_comparison
),

-- 3. 统计汇总
overall_stats AS (
    SELECT
        '数据覆盖' as analysis_type,
        'SOFA vs SOFA2' as comparison_type,
        CAST(COUNT(*) AS VARCHAR) as matched_patients,
        CAST(COUNT(DISTINCT stay_id) AS VARCHAR) as matched_stays,
        CAST(COUNT(DISTINCT subject_id) AS VARCHAR) as matched_subjects
    FROM base_comparison

    UNION ALL

    SELECT
        '评分范围',
        'SOFA-1 总分',
        CAST(MIN(sofa_total) AS VARCHAR) || ' - ' || CAST(MAX(sofa_total) AS VARCHAR),
        CAST(ROUND(AVG(sofa_total), 2) AS VARCHAR) as mean_score,
        CAST(ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_total)::numeric, 2) AS VARCHAR) as median_score
    FROM base_comparison

    UNION ALL

    SELECT
        '评分范围',
        'SOFA-2 总分',
        CAST(MIN(sofa2_total) AS VARCHAR) || ' - ' || CAST(MAX(sofa2_total) AS VARCHAR),
        CAST(ROUND(AVG(sofa2_total), 2) AS VARCHAR) as mean_score,
        CAST(ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_total)::numeric, 2) AS VARCHAR) as median_score
    FROM base_comparison
),

-- 4. 分布对比
distribution_comparison AS (
    SELECT
        'SOFA-1评分分布',
        score_category,
        patient_count,
        ROUND(patient_count * 100.0 / SUM(patient_count) OVER(), 2) as percentage
    FROM (
        SELECT
            CASE
                WHEN sofa_total = 0 THEN '0分'
                WHEN sofa_total BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa_total BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa_total BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa_total >= 12 THEN '12+分'
            END as score_category,
            COUNT(*) as patient_count
        FROM base_comparison
        GROUP BY
            CASE
                WHEN sofa_total = 0 THEN '0分'
                WHEN sofa_total BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa_total BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa_total BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa_total >= 12 THEN '12+分'
            END
    ) sofa1_dist

    UNION ALL

    SELECT
        'SOFA-2评分分布',
        score_category,
        patient_count,
        ROUND(patient_count * 100.0 / SUM(patient_count) OVER(), 2) as percentage
    FROM (
        SELECT
            CASE
                WHEN sofa2_total = 0 THEN '0分'
                WHEN sofa2_total BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa2_total BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa2_total BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa2_total >= 12 THEN '12+分'
            END as score_category,
            COUNT(*) as patient_count
        FROM base_comparison
        GROUP BY
            CASE
                WHEN sofa2_total = 0 THEN '0分'
                WHEN sofa2_total BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa2_total BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa2_total BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa2_total >= 12 THEN '12+分'
            END
    ) sofa2_dist
),

-- 5. 系统级对比
system_comparison AS (
    SELECT
        '呼吸系统',
        ROUND(AVG(sofa_respiration), 3) as sofa1_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_respiration)::numeric, 2) as sofa1_median,
        ROUND(AVG(sofa2_respiratory), 3) as sofa2_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_respiratory)::numeric, 2) as sofa2_median,
        ROUND(AVG(sofa2_respiratory - sofa_respiration), 3) as mean_difference,
        COUNT(CASE WHEN sofa2_respiratory > sofa_respiration THEN 1 END) as increased_count,
        COUNT(CASE WHEN sofa2_respiratory < sofa_respiration THEN 1 END) as decreased_count,
        COUNT(CASE WHEN sofa2_respiratory = sofa_respiration THEN 1 END) as same_count
    FROM base_comparison

    UNION ALL

    SELECT
        '凝血系统' || ' (CNS→Brain)',
        ROUND(AVG(sofa_cns), 3) as sofa1_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_cns)::numeric, 2) as sofa1_median,
        ROUND(AVG(sofa2_brain), 3) as sofa2_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_brain)::numeric, 2) as sofa2_median,
        ROUND(AVG(sofa2_brain - sofa_cns), 3) as mean_difference,
        COUNT(CASE WHEN sofa2_brain > sofa_cns THEN 1 END) as increased_count,
        COUNT(CASE WHEN sofa2_brain < sofa_cns THEN 1 END) as decreased_count,
        COUNT(CASE WHEN sofa2_brain = sofa_cns THEN 1 END) as same_count
    FROM base_comparison

    UNION ALL

    SELECT
        '心血管系统',
        ROUND(AVG(sofa_cardiovascular), 3) as sofa1_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_cardiovascular)::numeric, 2) as sofa1_median,
        ROUND(AVG(sofa2_cardiovascular), 3) as sofa2_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_cardiovascular)::numeric, 2) as sofa2_median,
        ROUND(AVG(sofa2_cardiovascular - sofa_cardiovascular), 3) as mean_difference,
        COUNT(CASE WHEN sofa2_cardiovascular > sofa_cardiovascular THEN 1 END) as increased_count,
        COUNT(CASE WHEN sofa2_cardiovascular < sofa_cardiovascular THEN 1 END) as decreased_count,
        COUNT(CASE WHEN sofa2_cardiovascular = sofa_cardiovascular THEN 1 END) as same_count
    FROM base_comparison

    UNION ALL

    SELECT
        '肝脏系统',
        ROUND(AVG(sofa_liver), 3) as sofa1_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_liver)::numeric, 2) as sofa1_median,
        ROUND(AVG(sofa2_liver), 3) as sofa2_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_liver)::numeric, 2) as sofa2_median,
        ROUND(AVG(sofa2_liver - sofa_liver), 3) as mean_difference,
        COUNT(CASE WHEN sofa2_liver > sofa_liver THEN 1 END) as increased_count,
        COUNT(CASE WHEN sofa2_liver < sofa_liver THEN 1 END) as decreased_count,
        COUNT(CASE WHEN sofa2_liver = sofa_liver THEN 1 END) as same_count
    FROM base_comparison

    UNION ALL

    SELECT
        '肾脏系统',
        ROUND(AVG(sofa_renal), 3) as sofa1_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_renal)::numeric, 2) as sofa1_median,
        ROUND(AVG(sofa2_kidney), 3) as sofa2_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_kidney)::numeric, 2) as sofa2_median,
        ROUND(AVG(sofa2_kidney - sofa_renal), 3) as mean_difference,
        COUNT(CASE WHEN sofa2_kidney > sofa_renal THEN 1 END) as increased_count,
        COUNT(CASE WHEN sofa2_kidney < sofa_renal THEN 1 END) as decreased_count,
        COUNT(CASE WHEN sofa2_kidney = sofa_renal THEN 1 END) as same_count
    FROM base_comparison

    UNION ALL

    SELECT
        '凝血系统' || ' (Coag→Hemostasis)',
        ROUND(AVG(sofa_coagulation), 3) as sofa1_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_coagulation)::numeric, 2) as sofa1_median,
        ROUND(AVG(sofa2_hemostasis), 3) as sofa2_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_hemostasis)::numeric, 2) as sofa2_median,
        ROUND(AVG(sofa2_hemostasis - sofa_coagulation), 3) as mean_difference,
        COUNT(CASE WHEN sofa2_hemostasis > sofa_coagulation THEN 1 END) as increased_count,
        COUNT(CASE WHEN sofa2_hemostasis < sofa_coagulation THEN 1 END) as decreased_count,
        COUNT(CASE WHEN sofa2_hemostasis = sofa_coagulation THEN 1 END) as same_count
    FROM base_comparison
),

-- 6. 总分差异统计
total_score_stats AS (
    SELECT
        '总分统计',
        ROUND(AVG(sofa_total), 3) as sofa1_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa_total)::numeric, 2) as sofa1_median,
        ROUND(AVG(sofa2_total), 3) as sofa2_mean,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_total)::numeric, 2) as sofa2_median,
        ROUND(AVG(sofa2_total - sofa_total), 3) as mean_difference,
        COUNT(CASE WHEN sofa2_total > sofa_total THEN 1 END) as increased_count,
        COUNT(CASE WHEN sofa2_total < sofa_total THEN 1 END) as decreased_count,
        COUNT(CASE WHEN sofa2_total = sofa_total THEN 1 END) as same_count
    FROM base_comparison
),

-- 7. 重症患者差异分析
severe_patient_analysis AS (
    SELECT
        '重症阈值对比',
        COUNT(CASE WHEN sofa_total >= 8 THEN 1 END) as sofa1_severe_count,
        ROUND(COUNT(CASE WHEN sofa_total >= 8 THEN 1 END) * 100.0 / COUNT(*), 2) as sofa1_severe_percentage,
        COUNT(CASE WHEN sofa2_total >= 8 THEN 1 END) as sofa2_severe_count,
        ROUND(COUNT(CASE WHEN sofa2_total >= 8 THEN 1 END) * 100.0 / COUNT(*), 2) as sofa2_severe_percentage,
        COUNT(CASE WHEN sofa_total >= 8 AND sofa2_total < 8 THEN 1 END) as downgrade_count,
        COUNT(CASE WHEN sofa_total < 8 AND sofa2_total >= 8 THEN 1 END) as upgrade_count
    FROM base_comparison
)

-- =================================================================
-- 输出对比结果
-- =================================================================

-- 1. 基础统计
SELECT '=== SOFA vs SOFA2 对比分析报告 ===' as report_section
UNION ALL
SELECT '' as report_section
UNION ALL
SELECT * FROM overall_stats
UNION ALL
SELECT '' as report_section
UNION ALL
SELECT '=== 评分分布对比 ===' as report_section
UNION ALL
SELECT * FROM distribution_comparison
UNION ALL
SELECT '' as report_section
UNION ALL
SELECT '=== 总分对比统计 ===' as report_section
UNION ALL
SELECT * FROM total_score_stats
UNION ALL
SELECT '' as report_section
UNION ALL
SELECT '=== 系统级评分对比 ===' as report_section
UNION ALL
SELECT * FROM system_comparison
UNION ALL
SELECT '' as report_section
UNION ALL
SELECT '=== 重症患者阈值分析 ===' as report_section
UNION ALL
SELECT * FROM severe_patient_analysis;

-- =================================================================
-- 详细差异分析 (可选)
-- =================================================================

-- 差异分布统计
SELECT '=== 总分差异分布统计 ===' as analysis_type
UNION ALL
SELECT
    '差异范围',
    '患者数量',
    '百分比'
FROM (
    SELECT
        CASE
            WHEN total_diff <= -3 THEN '减少3分以上'
            WHEN total_diff = -2 THEN '减少2分'
            WHEN total_diff = -1 THEN '减少1分'
            WHEN total_diff = 0 THEN '无变化'
            WHEN total_diff = 1 THEN '增加1分'
            WHEN total_diff = 2 THEN '增加2分'
            WHEN total_diff >= 3 THEN '增加3分以上'
        END as diff_category,
        COUNT(*) as patient_count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
    FROM score_differences
    GROUP BY
        CASE
            WHEN total_diff <= -3 THEN '减少3分以上'
            WHEN total_diff = -2 THEN '减少2分'
            WHEN total_diff = -1 THEN '减少1分'
            WHEN total_diff = 0 THEN '无变化'
            WHEN total_diff = 1 THEN '增加1分'
            WHEN total_diff = 2 THEN '增加2分'
            WHEN total_diff >= 3 THEN '增加3分以上'
        END
    ORDER BY MIN(total_diff)
) diff_stats;

-- 极端差异案例分析
SELECT '=== 极端差异案例分析 ===' as analysis_type
UNION ALL
SELECT
    'SOFA1大幅高于SOFA2 (差≥4分)' as case_type,
    CAST(COUNT(*) AS VARCHAR) as patient_count,
    '平均差异: ' || CAST(ROUND(AVG(total_diff), 2) AS VARCHAR) as avg_difference
FROM score_differences
WHERE total_diff <= -4

UNION ALL

SELECT
    'SOFA2大幅高于SOFA1 (差≥4分)' as case_type,
    CAST(COUNT(*) AS VARCHAR) as patient_count,
    '平均差异: ' || CAST(ROUND(AVG(total_diff), 2) AS VARCHAR) as avg_difference
FROM score_differences
WHERE total_diff >= 4;

-- 验证完成
SELECT '=== 对比分析完成 ===' as completion_status,
       '请查看详细结果并生成markdown报告' as next_step;