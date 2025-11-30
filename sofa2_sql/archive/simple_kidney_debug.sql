-- =================================================================
-- 简化分析：找出为什么SOFA2肾脏评分75%是3分
-- =================================================================

-- 1. 检查SOFA2肾脏评分为3分的患者到底满足哪个条件
WITH sofa2_kidney_3 AS (
    SELECT
        s.stay_id,
        s.hr,
        kl.creatinine,
        kl.potassium,
        kl.ph,
        kl.bicarbonate,
        rr.on_rrt,
        u.weight,
        u.cnt_24h,
        u.uo_sum_24h,

        -- 计算尿量速率
        CASE WHEN u.cnt_24h > 0 AND u.weight > 0
             THEN u.uo_sum_24h / u.weight / u.cnt_24h
             ELSE NULL END as urine_rate_24h,

        -- 检查各个条件
        CASE WHEN rr.on_rrt = 1 THEN 'RRT' END as condition_4,

        CASE WHEN (kl.creatinine > 1.2 OR (u.cnt_24h > 0 AND u.weight > 0 AND u.uo_sum_24h / u.weight / u.cnt_24h < 0.3))
             AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
             THEN 'Virtual RRT' END as condition_4b,

        CASE WHEN kl.creatinine > 3.5 THEN 'Creatinine > 3.5' END as condition_3a,

        CASE WHEN u.cnt_24h > 0 AND u.weight > 0 AND u.uo_sum_24h / u.weight / u.cnt_24h < 0.3
             THEN 'Urine < 0.3' END as condition_3b,

        CASE WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 'Anuria 12h' END as condition_3c,

        CASE WHEN kl.creatinine > 2.0 THEN 'Creatinine > 2.0' END as condition_2,

        CASE WHEN u.cnt_12h > 0 AND u.weight > 0 AND u.uo_sum_12h / u.weight / u.cnt_12h < 0.5
             THEN 'Urine < 0.5' END as condition_2b,

        CASE WHEN kl.creatinine > 1.2 THEN 'Creatinine > 1.2' END as condition_1,

        CASE WHEN u.cnt_6h > 0 AND u.weight > 0 AND u.uo_sum_6h / u.weight / u.cnt_6h < 0.5
             THEN 'Urine < 0.5' END as condition_1b

    FROM mimiciv_derived.sofa2_hourly_raw s
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON s.stay_id = kl.stay_id AND s.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON s.stay_id = rr.stay_id AND s.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON s.stay_id = u.stay_id AND s.hr = u.hr
    WHERE s.hr BETWEEN 0 AND 23
    AND s.kidney_score = 3  -- 只看评分为3分的记录
    AND kl.creatinine IS NOT NULL
)

-- 统计各个条件的触发情况
SELECT
    'Trigger Analysis for Score 3' as analysis_type,
    condition_4 as trigger_condition,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
WHERE condition_4 IS NOT NULL
GROUP BY condition_4

UNION ALL

SELECT
    'Trigger Analysis for Score 3' as analysis_type,
    condition_4b as trigger_condition,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
WHERE condition_4b IS NOT NULL
GROUP BY condition_4b

UNION ALL

SELECT
    'Trigger Analysis for Score 3' as analysis_type,
    condition_3a as trigger_condition,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
WHERE condition_3a IS NOT NULL
GROUP BY condition_3a

UNION ALL

SELECT
    'Trigger Analysis for Score 3' as analysis_type,
    condition_3b as trigger_condition,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
WHERE condition_3b IS NOT NULL
GROUP BY condition_3b

UNION ALL

SELECT
    'Trigger Analysis for Score 3' as analysis_type,
    condition_3c as trigger_condition,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
WHERE condition_3c IS NOT NULL
GROUP BY condition_3c

ORDER BY count DESC;

-- 2. 检查数值分布
SELECT
    'Key Values for Score 3' as analysis_type,
    'Creatinine Range' as metric_name,
    CASE
        WHEN creatinine < 1.2 THEN '< 1.2'
        WHEN creatinine < 2.0 THEN '1.2-1.9'
        WHEN creatinine < 3.5 THEN '2.0-3.4'
        WHEN creatinine >= 3.5 THEN '≥ 3.5'
    END as value_range,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
GROUP BY
    CASE
        WHEN creatinine < 1.2 THEN '< 1.2'
        WHEN creatinine < 2.0 THEN '1.2-1.9'
        WHEN creatinine < 3.5 THEN '2.0-3.4'
        WHEN creatinine >= 3.5 THEN '≥ 3.5'
    END
ORDER BY
    CASE
        WHEN creatinine < 1.2 THEN 1
        WHEN creatinine < 2.0 THEN 2
        WHEN creatinine < 3.5 THEN 3
        WHEN creatinine >= 3.5 THEN 4
    END

UNION ALL

SELECT
    'Key Values for Score 3' as analysis_type,
    'Urine Rate Range' as metric_name,
    CASE
        WHEN urine_rate_24h IS NULL THEN 'Missing'
        WHEN urine_rate_24h < 0.1 THEN '< 0.1'
        WHEN urine_rate_24h < 0.3 THEN '0.1-0.29'
        WHEN urine_rate_24h < 0.5 THEN '0.3-0.49'
        WHEN urine_rate_24h < 1.0 THEN '0.5-0.99'
        ELSE '≥ 1.0'
    END as value_range,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
GROUP BY
    CASE
        WHEN urine_rate_24h IS NULL THEN 'Missing'
        WHEN urine_rate_24h < 0.1 THEN '< 0.1'
        WHEN urine_rate_24h < 0.3 THEN '0.1-0.29'
        WHEN urine_rate_24h < 0.5 THEN '0.3-0.49'
        WHEN urine_rate_24h < 1.0 THEN '0.5-0.99'
        ELSE '≥ 1.0'
    END
ORDER BY
    CASE
        WHEN urine_rate_24h IS NULL THEN 1
        WHEN urine_rate_24h < 0.1 THEN 2
        WHEN urine_rate_24h < 0.3 THEN 3
        WHEN urine_rate_24h < 0.5 THEN 4
        WHEN urine_rate_24h < 1.0 THEN 5
        ELSE 6
    END;

-- 3. 检查cnt_24h的分布
SELECT
    'cnt_24h Distribution' as analysis_type,
    cnt_24h as hour_count,
    COUNT(*) as record_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM sofa2_kidney_3), 2) as percentage
FROM sofa2_kidney_3
WHERE cnt_24h IS NOT NULL
GROUP BY cnt_24h
ORDER BY cnt_24h;

-- 4. 抽样查看具体的评分案例
SELECT
    'Sample Cases' as analysis_type,
    stay_id,
    hr,
    ROUND(creatinine, 1) as creatinine,
    ROUND(potassium, 1) as potassium,
    ROUND(ph, 1) as ph,
    ROUND(bicarbonate, 1) as bicarbonate,
    on_rrt,
    ROUND(weight, 1) as weight,
    cnt_24h,
    ROUND(uo_sum_24h, 0) as urine_24h,
    ROUND(urine_rate_24h, 2) as urine_rate_24h,
    condition_3a,
    condition_3b,
    condition_3c
FROM sofa2_kidney_3
ORDER BY RANDOM()
LIMIT 20;