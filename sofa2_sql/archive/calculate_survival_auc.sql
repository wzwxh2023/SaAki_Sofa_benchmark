-- =================================================================
-- SOFA vs SOFA2 ICU生存预测AUC对比分析脚本
-- 功能：计算并比较SOFA和SOFA2评分对ICU患者生存预测的性能
-- 方法：使用每个患者的最后一次ICU住院，计算ROC AUC
-- =================================================================

-- 安装必要的PostgreSQL扩展（如果需要）
-- CREATE EXTENSION IF NOT EXISTS plpgsql;
-- 注意：ROC AUC计算可能需要额外的函数或统计包

-- 设置性能参数
SET work_mem = '512MB';
SET maintenance_work_mem = '512MB';
SET max_parallel_workers = 8;
SET max_parallel_workers_per_gather = 4;

-- =================================================================
-- 1. 提取每个患者的最后一次ICU住院记录
-- =================================================================
WITH last_icu_stays AS (
    SELECT
        f1.stay_id,
        f1.subject_id,
        f1.hadm_id,
        f1.icu_intime,
        f1.icu_outtime,
        f1.sofa AS sofa_score,
        f2.sofa2 AS sofa2_score,
        f1.icu_mortality,
        f1.hospital_expire_flag,
        f1.age,
        f1.gender,
        f1.icu_los_hours,

        -- 计算住院序号
        ROW_NUMBER() OVER (
            PARTITION BY f1.subject_id
            ORDER BY f1.icu_intime DESC, f1.stay_id DESC
        ) as admission_rank
    FROM mimiciv_derived.first_day_sofa f1
    INNER JOIN mimiciv_derived.first_day_sofa2 f2
        ON f1.stay_id = f2.stay_id
),

-- 2. 筛选最后一次住院
final_cohort AS (
    SELECT
        stay_id,
        subject_id,
        hadm_id,
        icu_intime,
        icu_outtime,
        sofa_score,
        sofa2_score,
        icu_mortality,
        hospital_expire_flag,
        age,
        gender,
        icu_los_hours
    FROM last_icu_stays
    WHERE admission_rank = 1
),

-- 3. 基础统计信息
cohort_stats AS (
    SELECT
        '队列统计' as analysis_type,
        '总患者数' as metric,
        CAST(COUNT(*) AS VARCHAR) as value
    FROM final_cohort

    UNION ALL

    SELECT
        '队列统计',
        'ICU死亡数',
        CAST(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) AS VARCHAR)
    FROM final_cohort

    UNION ALL

    SELECT
        '队列统计',
        'ICU死亡率',
        CAST(ROUND(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%'
    FROM final_cohort

    UNION ALL

    SELECT
        '队列统计',
        '医院死亡数',
        CAST(COUNT(CASE WHEN hospital_expire_flag = 1 THEN 1 END) AS VARCHAR)
    FROM final_cohort

    UNION ALL

    SELECT
        '队列统计',
        '医院死亡率',
        CAST(ROUND(COUNT(CASE WHEN hospital_expire_flag = 1 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%'
    FROM final_cohort
),

-- 4. 评分分布统计
score_distribution AS (
    SELECT
        '评分分布' as analysis_type,
        'SOFA平均分' as metric,
        CAST(ROUND(AVG(sofa_score), 2) AS VARCHAR) as value
    FROM final_cohort

    UNION ALL

    SELECT
        '评分分布',
        'SOFA-2平均分',
        CAST(ROUND(AVG(sofa2_score), 2) AS VARCHAR)
    FROM final_cohort

    UNION ALL

    SELECT
        '评分分布',
        'SOFA标准差',
        CAST(ROUND(STDDEV(sofa_score), 2) AS VARCHAR)
    FROM final_cohort

    UNION ALL

    SELECT
        '评分分布',
        'SOFA-2标准差',
        CAST(ROUND(STDDEV(sofa2_score), 2) AS VARCHAR)
    FROM final_cohort
),

-- 5. 分层死亡率分析
mortality_by_score AS (
    SELECT
        '分层死亡率分析' as analysis_type,
        score_category,
        sofa_deaths,
        sofa_total,
        CAST(ROUND(sofa_deaths * 100.0 / NULLIF(sofa_total, 0), 2) AS VARCHAR) || '%' as sofa_mortality,
        sofa2_deaths,
        sofa2_total,
        CAST(ROUND(sofa2_deaths * 100.0 / NULLIF(sofa2_total, 0), 2) AS VARCHAR) || '%' as sofa2_mortality
    FROM (
        -- SOFA分层分析
        SELECT
            CASE
                WHEN sofa_score = 0 THEN '0分'
                WHEN sofa_score BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa_score BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa_score BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa_score >= 12 THEN '12+分'
            END as score_category,
            COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) as sofa_deaths,
            COUNT(*) as sofa_total,
            0 as sofa2_deaths,
            0 as sofa2_total
        FROM final_cohort
        GROUP BY
            CASE
                WHEN sofa_score = 0 THEN '0分'
                WHEN sofa_score BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa_score BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa_score BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa_score >= 12 THEN '12+分'
            END

        UNION ALL

        -- SOFA-2分层分析
        SELECT
            CASE
                WHEN sofa2_score = 0 THEN '0分'
                WHEN sofa2_score BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa2_score BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa2_score BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa2_score >= 12 THEN '12+分'
            END as score_category,
            0 as sofa_deaths,
            0 as sofa_total,
            COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) as sofa2_deaths,
            COUNT(*) as sofa2_total
        FROM final_cohort
        GROUP BY
            CASE
                WHEN sofa2_score = 0 THEN '0分'
                WHEN sofa2_score BETWEEN 1 AND 3 THEN '1-3分'
                WHEN sofa2_score BETWEEN 4 AND 7 THEN '4-7分'
                WHEN sofa2_score BETWEEN 8 AND 11 THEN '8-11分'
                WHEN sofa2_score >= 12 THEN '12+分'
            END
    ) layered_analysis
    GROUP BY score_category, sofa_deaths, sofa_total, sofa2_deaths, sofa2_total
)

-- =================================================================
-- 6. 手动计算AUC的简化方法
-- 由于PostgreSQL原生不支持ROC AUC计算，我们使用Wilcoxon-Mann-Whitney方法
-- =================================================================
WITH auc_calculation AS (
    SELECT
        -- SOFA AUC计算 (使用Mann-Whitney U统计量的转换)
        (
            SELECT COUNT(*) FROM final_cohort a, final_cohort b
            WHERE a.icu_mortality = 1 AND b.icu_mortality = 0 AND a.sofa_score > b.sofa_score
        ) /
        NULLIF(
            (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 1) *
            (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 0), 0
        ) as sofa_auc,

        -- SOFA-2 AUC计算
        (
            SELECT COUNT(*) FROM final_cohort a, final_cohort b
            WHERE a.icu_mortality = 1 AND b.icu_mortality = 0 AND a.sofa2_score > b.sofa2_score
        ) /
        NULLIF(
            (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 1) *
            (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 0), 0
        ) as sofa2_auc
),

-- 7. 简化的AUC验证（使用百分位方法）
auc_validation AS (
    SELECT
        'AUC计算验证' as analysis_type,
        metric_name,
        metric_value
    FROM (
        -- 验证SOFA AUC
        SELECT
            'SOFA AUC Mann-Whitney',
            CAST(ROUND(
                (SELECT COUNT(*) FROM final_cohort a, final_cohort b
                 WHERE a.icu_mortality = 1 AND b.icu_mortality = 0 AND a.sofa_score > b.sofa_score
                )::NUMERIC /
                NULLIF(
                    (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 1)::NUMERIC *
                    (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 0)::NUMERIC, 0
                ), 3
            ) AS VARCHAR)

        UNION ALL

        -- 验证SOFA-2 AUC
        SELECT
            'SOFA-2 AUC Mann-Whitney',
            CAST(ROUND(
                (SELECT COUNT(*) FROM final_cohort a, final_cohort b
                 WHERE a.icu_mortality = 1 AND b.icu_mortality = 0 AND a.sofa2_score > b.sofa2_score
                )::NUMERIC /
                NULLIF(
                    (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 1)::NUMERIC *
                    (SELECT COUNT(*) FROM final_cohort WHERE icu_mortality = 0)::NUMERIC, 0
                ), 3
            ) AS VARCHAR)
    ) auc_validation_metrics
)

-- =================================================================
-- 输出结果
-- =================================================================

-- 显示基础统计
SELECT * FROM cohort_stats
UNION ALL
SELECT '' as analysis_type, '', ''
UNION ALL
SELECT * FROM score_distribution
UNION ALL
SELECT '' as analysis_type, '', ''
UNION ALL
SELECT * FROM mortality_by_score;

-- 显示AUC计算结果
SELECT '=== AUC计算结果 ===' as analysis_section
UNION ALL
SELECT '注意：由于PostgreSQL限制，此处使用Mann-Whitney U方法估算AUC' as analysis_section
UNION ALL
SELECT '建议：使用Python/R进行精确AUC计算以获得更准确结果' as analysis_section;

-- 保存数据用于外部AUC计算
SELECT
    stay_id,
    subject_id,
    icu_mortality,
    sofa_score,
    sofa2_score
FROM final_cohort
ORDER BY subject_id, icu_intime;