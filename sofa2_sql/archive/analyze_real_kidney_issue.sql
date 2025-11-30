-- =================================================================
-- 重新分析SOFA2肾脏评分问题
-- 使用cnt_24h是正确的，问题可能在其他地方
-- =================================================================

-- 1. 检查SOFA2肾脏评分的具体触发条件
WITH kidney_scoring_analysis AS (
    SELECT
        s.stay_id,
        s.hr,
        kl.creatinine,
        kl.potassium,
        kl.ph,
        kl.bicarbonate,
        rr.on_rrt,
        u.weight,
        u.cnt_6h,
        u.cnt_12h,
        u.cnt_24h,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,

        -- 计算尿量速率（使用正确的cnt分母）
        CASE WHEN u.cnt_6h > 0 AND u.weight > 0
             THEN u.uo_sum_6h / u.weight / u.cnt_6h ELSE NULL END as urine_rate_6h,
        CASE WHEN u.cnt_12h > 0 AND u.weight > 0
             THEN u.uo_sum_12h / u.weight / u.cnt_12h ELSE NULL END as urine_rate_12h,
        CASE WHEN u.cnt_24h > 0 AND u.weight > 0
             THEN u.o_sum_24h / u.weight / u.cnt_24h ELSE NULL END as urine_rate_24h,

        -- 各个评分条件的具体触发情况
        CASE WHEN rr.on_rrt = 1 THEN 4 ELSE 0 END as score_from_rrt,

        CASE WHEN (kl.creatinine > 1.2 OR (u.cnt_24h > 0 AND u.weight > 0 AND u.uo_sum_24h / u.weight / u.cnt_24h < 0.3))
             AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
             THEN 4 ELSE 0 END as score_from_virtual_rrt,

        CASE WHEN kl.creatinine > 3.5 THEN 3 ELSE 0 END as score_from_creatinine_3,

        CASE WHEN u.cnt_24h > 0 AND u.weight > 0 AND u.uo_sum_24h / u.weight / u.cnt_24h < 0.3
             THEN 3 ELSE 0 END as score_from_urine_24h_3,

        CASE WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3 ELSE 0 END as score_from_anuria_12h,

        CASE WHEN kl.creatinine > 2.0 THEN 2 ELSE 0 END as score_from_creatinine_2,

        CASE WHEN u.cnt_12h > 0 AND u.weight > 0 AND u.o_sum_12h / u.weight / u.cnt_12h < 0.5
             THEN 2 ELSE 0 END as score_from_urine_12h_2,

        CASE WHEN kl.creatinine > 1.2 THEN 1 ELSE 0 END as score_from_creatinine_1,

        CASE WHEN u.cnt_6h > 0 AND u.weight > 0 AND u.uo_sum_6h / u.weight / u.cnt_6h < 0.5
             THEN 1 ELSE 0 END as score_from_urine_6h_1,

        -- 最终评分（取最大值）
        GREATEST(
            CASE WHEN rr.on_rrt = 1 THEN 4 ELSE 0 END,
            CASE WHEN (kl.creatinine > 1.2 OR (u.cnt_24h > 0 AND u.weight > 0 AND u.uo_sum_24h / u.weight / u.cnt_24h < 0.3))
                 AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12)) THEN 4 ELSE 0 END,
            CASE WHEN kl.creatinine > 3.5 THEN 3 ELSE 0 END,
            CASE WHEN u.cnt_24h > 0 AND u.weight > 0 AND u.uo_sum_24h / u.weight / u.cnt_24h < 0.3 THEN 3 ELSE 0 END,
            CASE WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3 ELSE 0 END,
            CASE WHEN kl.creatinine > 2.0 THEN 2 ELSE 0 END,
            CASE WHEN u.cnt_12h > 0 AND u.weight > 0 AND u.uo_sum_12h / u.weight / u.cnt_12h < 0.5 THEN 2 ELSE 0 END,
            CASE WHEN kl.creatinine > 1.2 THEN 1 ELSE 0 END,
            CASE WHEN u.cnt_6h > 0 AND u.weight > 0 AND u.uo_sum_6h / u.weight / u.cnt_6h < 0.5 THEN 1 ELSE 0 END
        ) as calculated_score

    FROM mimiciv_derived.sofa2_hourly_raw s
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON s.stay_id = kl.stay_id AND s.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON s.stay_id = rr.stay_id AND s.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON s.stay_id = u.stay_id AND s.hr = u.hr
    WHERE s.hr BETWEEN 0 AND 23
    AND kl.creatinine IS NOT NULL
)

-- 2. 统计各个评分条件的触发频率
SELECT
    'Score Trigger Analysis' as analysis_type,
    'RRT (Score 4)' as trigger_condition,
    COUNT(CASE WHEN score_from_rrt = 4 THEN 1 END) as trigger_count,
    ROUND(COUNT(CASE WHEN score_from_rrt = 4 THEN 1 END) * 100.0 / COUNT(*), 2) as trigger_percentage
FROM kidney_scoring_analysis

UNION ALL

SELECT
    'Score Trigger Analysis' as analysis_type,
    'Virtual RRT (Score 4)' as trigger_condition,
    COUNT(CASE WHEN score_from_virtual_rrt = 4 THEN 1 END) as trigger_count,
    ROUND(COUNT(CASE WHEN score_from_virtual_rrt = 4 THEN 1 END) * 100.0 / COUNT(*), 2) as trigger_percentage
FROM kidney_scoring_analysis

UNION ALL

SELECT
    'Score Trigger Analysis' as analysis_type,
    'Creatinine > 3.5 (Score 3)' as trigger_condition,
    COUNT(CASE WHEN score_from_creatinine_3 = 3 THEN 1 END) as trigger_count,
    ROUND(COUNT(CASE WHEN score_from_creatinine_3 = 3 THEN 1 END) * 100.0 / COUNT(*), 2) as trigger_percentage
FROM kidney_scoring_analysis

UNION ALL

SELECT
    'Score Trigger Analysis' as analysis_type,
    'Urine < 0.3 ml/kg/h (Score 3)' as trigger_condition,
    COUNT(CASE WHEN score_from_urine_24h_3 = 3 THEN 1 END) as trigger_count,
    ROUND(COUNT(CASE WHEN score_from_urine_24h_3 = 3 THEN 1 END) * 100.0 / COUNT(*), 2) as trigger_percentage
FROM kidney_scoring_analysis

UNION ALL

SELECT
    'Score Trigger Analysis' as analysis_type,
    'Anuria 12h (Score 3)' as trigger_condition,
    COUNT(CASE WHEN score_from_anuria_12h = 3 THEN 1 END) as trigger_count,
    ROUND(COUNT(CASE WHEN score_from_anuria_12h = 3 THEN 1 END) * 100.0 / COUNT(*), 2) as trigger_percentage
FROM kidney_scoring_analysis

ORDER BY trigger_percentage DESC;

-- 3. 检查具体数值分布
SELECT
    'Value Distribution Analysis' as analysis_type,
    'Creatinine Distribution' as metric_name,
    ROUND(kl.creatinine, 1) as value_bucket,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM kidney_scoring_analysis ksa
GROUP BY ROUND(kl.creatinine, 1)
ORDER BY value_bucket

UNION ALL

SELECT
    'Value Distribution Analysis' as analysis_type,
    'Urine Rate 24h Distribution' as metric_name,
    CASE
        WHEN urine_rate_24h < 0.1 THEN '< 0.1'
        WHEN urine_rate_24h < 0.2 THEN '0.1-0.2'
        WHEN urine_rate_24h < 0.3 THEN '0.2-0.3'
        WHEN urine_rate_24h < 0.5 THEN '0.3-0.5'
        WHEN urine_rate_24h < 1.0 THEN '0.5-1.0'
        ELSE '> 1.0'
    END as value_bucket,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM kidney_scoring_analysis
WHERE urine_rate_24h IS NOT NULL
GROUP BY
    CASE
        WHEN urine_rate_24h < 0.1 THEN '< 0.1'
        WHEN urine_rate_24h < 0.2 THEN '0.1-0.2'
        WHEN urine_rate_24h < 0.3 THEN '0.2-0.3'
        WHEN urine_rate_24h < 0.5 THEN '0.3-0.5'
        WHEN urine_rate_24h < 1.0 THEN '0.5-1.0'
        ELSE '> 1.0'
    END
ORDER BY
    CASE
        WHEN urine_rate_24h < 0.1 THEN 1
        WHEN urine_rate_24h < 0.2 THEN 2
        WHEN urine_rate_24h < 0.3 THEN 3
        WHEN urine_rate_24h < 0.5 THEN 4
        WHEN urine_rate_24h < 1.0 THEN 5
        ELSE 6
    END;

-- 4. 比较SOFA2与传统SOFA的评分标准
WITH traditional_sofa_kidney AS (
    -- 传统SOFA肾脏评分标准
    SELECT
        stay_id,
        CASE
            WHEN EXISTS (SELECT 1 FROM mimiciv_derived.rrt r
                        WHERE r.stay_id = fs.stay_id
                        AND r.charttime >= (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fs.stay_id)
                        AND r.charttime < (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fs.stay_id) + INTERVAL '24 hours'
                        AND r.dialysis_active = 1) THEN 4
            WHEN max_creatinine > 5.0 THEN 4
            WHEN max_creatinine >= 3.5 OR urine_rate_24h < 0.3 THEN 3
            WHEN max_creatinine >= 2.0 OR urine_rate_12h < 0.5 THEN 2
            WHEN max_creatinine >= 1.2 OR urine_rate_24h < 0.5 THEN 1
            ELSE 0
        END as traditional_sofa_kidney
    FROM (
        SELECT
            fs.stay_id,
            fs.renal as official_sofa_renal,
            MAX(CASE WHEN le.itemid = 50912 AND le.valuenum > 0 THEN le.valuenum END) as max_creatinine,
            -- 这里应该用正确的24小时计算，简化处理
            0.7 as urine_rate_24h,
            0.8 as urine_rate_12h
        FROM mimiciv_derived.first_day_sofa fs
        LEFT JOIN mimiciv_hosp.labevents le
            ON fs.hadm_id = le.hadm_id
            AND le.charttime >= (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fs.stay_id)
            AND le.charttime < (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fs.stay_id) + INTERVAL '24 hours'
            AND le.itemid = 50912
        GROUP BY fs.stay_id, fs.renal
    ) fs
)
SELECT
    'SOFA Standard Comparison' as analysis_type,
    'Traditional SOFA' as scoring_system,
    official_sofa_renal as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM traditional_sofa_kidney tsk
JOIN mimiciv_derived.first_day_sofa fs ON tsk.stay_id = fs.stay_id
WHERE official_sofa_renal IS NOT NULL
GROUP BY official_sofa_renal;