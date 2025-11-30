-- =================================================================
-- 检查尿量阈值分析
-- 0.3 ml/kg/h for 24h = 7.2 ml/kg/24h
-- 对于70kg患者 = 504 ml/24h
-- =================================================================

-- 1. 检查SOFA2肾脏评分为3分的患者的尿量分布
SELECT
    'Urine Output Analysis for SOFA2 Score 3' as analysis_type,
    -- 按体重分类
    CASE
        WHEN weight < 50 THEN '<50 kg'
        WHEN weight < 60 THEN '50-59 kg'
        WHEN weight < 70 THEN '60-69 kg'
        WHEN weight < 80 THEN '70-79 kg'
        WHEN weight < 90 THEN '80-89 kg'
        WHEN weight < 100 THEN '90-99 kg'
        ELSE '≥100 kg'
    END as weight_category,

    -- 计算平均体重和24小时尿量
    ROUND(AVG(weight), 1) as avg_weight_kg,
    ROUND(AVG(uo_sum_24h), 0) as avg_urine_24h_ml,

    -- 计算实际尿量速率
    ROUND(AVG(uo_sum_24h / weight / cnt_24h), 3) as avg_actual_urine_rate_ml_kg_h,

    -- 计算理论阈值（504ml对应70kg，按体重调整）
    ROUND(AVG(weight), 1) * 7.2 as expected_threshold_ml_24h,

    -- 检查是否真的低于阈值
    COUNT(CASE WHEN uo_sum_24h < (weight * 7.2) THEN 1 END) as below_threshold_count,
    COUNT(*) as total_count,
    ROUND(COUNT(CASE WHEN uo_sum_24h < (weight * 7.2) THEN 1 END) * 100.0 / COUNT(*), 2) as below_threshold_percentage

FROM (
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
        u.uo_sum_24h
    FROM mimiciv_derived.sofa2_hourly_raw s
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON s.stay_id = kl.stay_id AND s.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON s.stay_id = rr.stay_id AND s.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON s.stay_id = u.stay_id AND s.hr = u.hr
    WHERE s.hr BETWEEN 0 AND 23
    AND s.kidney_score = 3
    AND kl.creatinine IS NOT NULL
    AND u.weight > 0
    AND u.cnt_24h > 0
    AND u.uo_sum_24h IS NOT NULL
) data
GROUP BY
    CASE
        WHEN weight < 50 THEN '<50 kg'
        WHEN weight < 60 THEN '50-59 kg'
        WHEN weight < 70 THEN '60-69 kg'
        WHEN weight < 80 THEN '70-79 kg'
        WHEN weight < 90 THEN '80-89 kg'
        WHEN weight < 100 THEN '90-99 kg'
        ELSE '≥100 kg'
    END
ORDER BY avg_weight_kg;

-- 2. 检查传统SOFA评分为3分的患者的尿量分布
SELECT
    'Urine Output Analysis for Traditional SOFA Score 3' as analysis_type,
    -- 按体重分类
    CASE
        WHEN weight < 50 THEN '<50 kg'
        WHEN weight < 60 THEN '50-59 kg'
        WHEN weight < 70 THEN '60-69 kg'
        WHEN weight < 80 THEN '70-79 kg'
        WHEN weight < 90 THEN '80-89 kg'
        WHEN weight < 100 THEN '90-99 kg'
        ELSE '≥100 kg'
    END as weight_category,

    -- 计算平均体重和24小时尿量
    ROUND(AVG(COALESCE(weight, 70)), 1) as avg_weight_kg,
    ROUND(AVG(uo_sum_24h), 0) as avg_urine_24h_ml,

    -- 计算实际尿量速率
    ROUND(AVG(uo_sum_24h / COALESCE(weight, 70) / 24), 3) as avg_actual_urine_rate_ml_kg_h,

    -- 计算理论阈值
    ROUND(AVG(COALESCE(weight, 70)), 1) * 7.2 as expected_threshold_ml_24h,

    COUNT(*) as total_count

FROM (
    SELECT
        fs.stay_id,
        fs.renal as traditional_sofa_kidney,
        COALESCE(avg_weight.weight, 70) as weight,
        COALESCE(uo_total.total_urine_24h, 0) as uo_sum_24h
    FROM mimiciv_derived.first_day_sofa fs
    -- 获取体重信息
    LEFT JOIN (
        SELECT stay_id, AVG(weight) as weight
        FROM mimiciv_derived.weight_durations
        WHERE weight > 0
        GROUP BY stay_id
    ) avg_weight ON fs.stay_id = avg_weight.stay_id
    -- 获取24小时尿量
    LEFT JOIN (
        SELECT
            ie.stay_id,
            SUM(uo.urineoutput) as total_urine_24h
        FROM mimiciv_icu.icustays ie
        JOIN mimiciv_derived.urine_output uo
            ON ie.stay_id = uo.stay_id
            AND uo.charttime >= ie.intime
            AND uo.charttime < ie.intime + INTERVAL '24 hours'
        GROUP BY ie.stay_id
    ) uo_total ON fs.stay_id = uo_total.stay_id
    WHERE fs.renal = 3
) data
WHERE avg_urine_24h_ml > 0  -- 排除无尿量记录的
GROUP BY
    CASE
        WHEN weight < 50 THEN '<50 kg'
        WHEN weight < 60 THEN '50-59 kg'
        WHEN weight < 70 THEN '60-69 kg'
        WHEN weight < 80 THEN '70-79 kg'
        WHEN weight < 90 THEN '80-89 kg'
        WHEN weight < 100 THEN '90-99 kg'
        ELSE '≥100 kg'
    END
ORDER BY avg_weight_kg;

-- 3. 直接比较70kg患者的24小时尿量阈值
SELECT
    'Direct 70kg Comparison' as analysis_type,
    scoring_system,
    COUNT(*) as patient_count,
    ROUND(AVG(urine_24h_ml), 0) as avg_urine_24h_ml,
    ROUND(AVG(urine_rate_ml_kg_h), 3) as avg_urine_rate_ml_kg_h,
    ROUND(AVG(urine_24h_ml), 0) / 504 as ratio_to_threshold,
    COUNT(CASE WHEN urine_24h_ml < 504 THEN 1 END) as below_504ml_count,
    ROUND(COUNT(CASE WHEN urine_24h_ml < 504 THEN 1 END) * 100.0 / COUNT(*), 2) as below_504ml_percentage

FROM (
    -- SOFA2评分3分的70kg左右患者
    SELECT
        'SOFA2 Score 3' as scoring_system,
        uo_sum_24h as urine_24h_ml,
        uo_sum_24h / 70 / cnt_24h as urine_rate_ml_kg_h,
        weight
    FROM (
        SELECT
            s.stay_id,
            s.hr,
            kl.creatinine,
            u.weight,
            u.cnt_24h,
            u.uo_sum_24h
        FROM mimiciv_derived.sofa2_hourly_raw s
        LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON s.stay_id = kl.stay_id AND s.hr = kl.hr
        LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON s.stay_id = u.stay_id AND s.hr = u.hr
        WHERE s.hr BETWEEN 0 AND 23
        AND s.kidney_score = 3
        AND kl.creatinine IS NOT NULL
        AND u.weight BETWEEN 68 AND 72  -- 70kg左右
        AND u.cnt_24h > 0
        AND u.uo_sum_24h IS NOT NULL
    ) filtered_data

    UNION ALL

    -- 传统SOFA评分3分的70kg左右患者
    SELECT
        'Traditional SOFA Score 3' as scoring_system,
        total_urine_24h as urine_24h_ml,
        total_urine_24h / 70 / 24 as urine_rate_ml_kg_h,
        70 as weight
    FROM (
        SELECT
            fs.stay_id,
            fs.renal,
            uo_total.total_urine_24h
        FROM mimiciv_derived.first_day_sofa fs
        LEFT JOIN (
            SELECT
                ie.stay_id,
                SUM(uo.urineoutput) as total_urine_24h
            FROM mimiciv_icu.icustays ie
            JOIN mimiciv_derived.urine_output uo
                ON ie.stay_id = uo.stay_id
                AND uo.charttime >= ie.intime
                AND uo.charttime < ie.intime + INTERVAL '24 hours'
            GROUP BY ie.stay_id
        ) uo_total ON fs.stay_id = uo_total.stay_id
        WHERE fs.renal = 3
        AND uo_total.total_urine_24h IS NOT NULL
        AND uo_total.total_urine_24h > 0
    ) data
    WHERE ABS(70 - COALESCE((
        SELECT AVG(weight) FROM mimiciv_derived.weight_durations wd
        WHERE wd.stay_id = data.stay_id AND wd.weight > 0
    ), 70)) <= 2  -- 允许2kg误差
) comparison_data
GROUP BY scoring_system;

-- 4. 检查可能的尿量数据问题
SELECT
    'Data Quality Check' as analysis_type,
    'SOFA2 Urine Data' as data_source,
    COUNT(*) as total_records,
    COUNT(CASE WHEN uo_sum_24h = 0 THEN 1 END) as zero_urine_count,
    COUNT(CASE WHEN uo_sum_24h < 100 THEN 1 END) as very_low_urine_count,
    COUNT(CASE WHEN uo_sum_24h > 5000 THEN 1 END) as very_high_urine_count,
    ROUND(AVG(uo_sum_24h), 0) as avg_urine_24h,
    ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY uo_sum_24h), 0) as p25_urine_24h,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY uo_sum_24h), 0) as median_urine_24h,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY uo_sum_24h), 0) as p75_urine_24h
FROM mimiciv_derived.sofa2_stage1_urine
WHERE hr BETWEEN 0 AND 23
AND weight > 0
AND cnt_24h > 0
AND uo_sum_24h IS NOT NULL;