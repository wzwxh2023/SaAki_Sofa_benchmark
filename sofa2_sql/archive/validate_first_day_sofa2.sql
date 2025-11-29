-- =================================================================
-- 验证首日SOFA2评分表的数据质量
-- =================================================================

-- 设置性能参数
SET work_mem = '256MB';

-- =================================================================
-- 1. 基本数据质量验证
-- =================================================================
SELECT '=== 首日SOFA2数据质量验证报告 ===' as validation_section;

-- 基本统计
WITH basic_stats AS (
    SELECT
        '总记录数' as metric,
        COUNT(*) as value
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '独立ICU住院数',
        COUNT(DISTINCT stay_id)
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '独立患者数',
        COUNT(DISTINCT subject_id)
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '数据完整性(24h测量)',
        COUNT(CASE WHEN data_completeness = 'Complete' THEN 1 END)
    FROM mimiciv_derived.first_day_sofa2
)
SELECT * FROM basic_stats;

-- =================================================================
-- 2. SOFA2评分分布验证
-- =================================================================
SELECT '--- SOFA2评分分布 ---' as validation_section;

WITH sofa2_distribution AS (
    SELECT
        CASE
            WHEN sofa2 = 0 THEN '0分 (正常)'
            WHEN sofa2 BETWEEN 1 AND 3 THEN '1-3分 (轻度)'
            WHEN sofa2 BETWEEN 4 AND 7 THEN '4-7分 (中度)'
            WHEN sofa2 BETWEEN 8 AND 11 THEN '8-11分 (重度)'
            WHEN sofa2 >= 12 THEN '12+分 (极重度)'
        END as score_category,
        COUNT(*) as count,
        ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
    FROM mimiciv_derived.first_day_sofa2
    GROUP BY
        CASE
            WHEN sofa2 = 0 THEN '0分 (正常)'
            WHEN sofa2 BETWEEN 1 AND 3 THEN '1-3分 (轻度)'
            WHEN sofa2 BETWEEN 4 AND 7 THEN '4-7分 (中度)'
            WHEN sofa2 BETWEEN 8 AND 11 THEN '8-11分 (重度)'
            WHEN sofa2 >= 12 THEN '12+分 (极重度)'
        END
    ORDER BY MIN(sofa2)
)
SELECT * FROM sofa2_distribution;

-- =================================================================
-- 3. 各系统评分统计
-- =================================================================
SELECT '--- 各系统评分统计 ---' as validation_section;

SELECT
    '神经系统(Brain)' as organ_system,
    ROUND(AVG(brain), 2) as avg_score,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY brain), 2) as median_score,
    MAX(brain) as max_score,
    COUNT(CASE WHEN brain >= 2 THEN 1 END) as abnormal_count,
    ROUND(COUNT(CASE WHEN brain >= 2 THEN 1 END) * 100.0 / COUNT(*), 2) as abnormal_percentage
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '呼吸系统(Respiratory)',
    ROUND(AVG(respiratory), 2),
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY respiratory), 2),
    MAX(respiratory),
    COUNT(CASE WHEN respiratory >= 2 THEN 1 END),
    ROUND(COUNT(CASE WHEN respiratory >= 2 THEN 1 END) * 100.0 / COUNT(*), 2)
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '心血管系统(Cardiovascular)',
    ROUND(AVG(cardiovascular), 2),
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cardiovascular), 2),
    MAX(cardiovascular),
    COUNT(CASE WHEN cardiovascular >= 2 THEN 1 END),
    ROUND(COUNT(CASE WHEN cardiovascular >= 2 THEN 1 END) * 100.0 / COUNT(*), 2)
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '肝脏系统(Liver)',
    ROUND(AVG(liver), 2),
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY liver), 2),
    MAX(liver),
    COUNT(CASE WHEN liver >= 2 THEN 1 END),
    ROUND(COUNT(CASE WHEN liver >= 2 THEN 1 END) * 100.0 / COUNT(*), 2)
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '肾脏系统(Kidney)',
    ROUND(AVG(kidney), 2),
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kidney), 2),
    MAX(kidney),
    COUNT(CASE WHEN kidney >= 2 THEN 1 END),
    ROUND(COUNT(CASE WHEN kidney >= 2 THEN 1 END) * 100.0 / COUNT(*), 2)
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '凝血系统(Hemostasis)',
    ROUND(AVG(hemostasis), 2),
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hemostasis), 2),
    MAX(hemostasis),
    COUNT(CASE WHEN hemostasis >= 2 THEN 1 END),
    ROUND(COUNT(CASE WHEN hemostasis >= 2 THEN 1 END) * 100.0 / COUNT(*), 2)
FROM mimiciv_derived.first_day_sofa2;

-- =================================================================
-- 4. 临床指标验证
-- =================================================================
SELECT '--- 临床指标验证 ---' as validation_section;

WITH clinical_metrics AS (
    SELECT
        '平均SOFA2评分' as metric,
        ROUND(AVG(sofa2), 2) as value
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '中位数SOFA2评分',
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2), 2)
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '最大SOFA2评分',
        MAX(sofa2)::text
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '重症患者比例(SOFA2>=8)',
        ROUND(COUNT(CASE WHEN sofa2 >= 8 THEN 1 END) * 100.0 / COUNT(*), 2)::text || '%'
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '器官衰竭患者比例(SOFA2>=2)',
        ROUND(COUNT(CASE WHEN sofa2 >= 2 THEN 1 END) * 100.0 / COUNT(*), 2)::text || '%'
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        '平均衰竭器官数量',
        ROUND(AVG(failing_organs_count), 2)::text
    FROM mimiciv_derived.first_day_sofa2

    UNION ALL

    SELECT
        'ICU死亡率',
        ROUND(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) * 100.0 / COUNT(*), 2)::text || '%'
    FROM mimiciv_derived.first_day_sofa2
)
SELECT * FROM clinical_metrics;

-- =================================================================
-- 5. 数据完整性检查
-- =================================================================
SELECT '--- 数据完整性检查 ---' as validation_section;

SELECT
    data_completeness,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage,
    ROUND(AVG(sofa2), 2) as avg_sofa2
FROM mimiciv_derived.first_day_sofa2
GROUP BY data_completeness
ORDER BY percentage DESC;

-- =================================================================
-- 6. 验证完成总结
-- =================================================================
SELECT '=== 验证完成 ===' as validation_section;

SELECT
    '✅ 首日SOFA2表验证完成' as status,
    '记录数: ' || CAST(COUNT(*) AS VARCHAR) ||
    ' | 平均评分: ' || CAST(ROUND(AVG(sofa2), 2) AS VARCHAR) ||
    ' | 重症比例: ' || CAST(ROUND(COUNT(CASE WHEN sofa2 >= 8 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%' as summary
FROM mimiciv_derived.first_day_sofa2;