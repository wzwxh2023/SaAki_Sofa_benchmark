-- =================================================================
-- 调试SOFA2肾脏评分计算逻辑
-- =================================================================

-- 1. 检查尿量计算中的权重（weight）和count计算
WITH urine_debug AS (
    SELECT
        u.stay_id,
        u.hr,
        u.weight,
        u.cnt_6h,
        u.cnt_12h,
        u.cnt_24h,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,
        -- 计算尿量速率（ml/kg/hr）
        CASE WHEN u.cnt_6h > 0 THEN u.uo_sum_6h / u.weight / u.cnt_6h ELSE NULL END as uo_rate_6h,
        CASE WHEN u.cnt_12h > 0 THEN u.uo_sum_12h / u.weight / u.cnt_12h ELSE NULL END as uo_rate_12h,
        CASE WHEN u.cnt_24h > 0 THEN u.uo_sum_24h / u.weight / u.cnt_24h ELSE NULL END as uo_rate_24h,

        -- 评分阈值检查
        CASE WHEN u.cnt_6h > 0 AND (u.uo_sum_6h / u.weight / u.cnt_6h) < 0.5 THEN 1 ELSE 0 END as score_1_check_6h,
        CASE WHEN u.cnt_12h > 0 AND (u.uo_sum_12h / u.weight / u.cnt_12h) < 0.5 THEN 2 ELSE 0 END as score_2_check_12h,
        CASE WHEN u.cnt_24h > 0 AND (u.uo_sum_24h / u.weight / u.cnt_24h) < 0.3 THEN 3 ELSE 0 END as score_3_check_24h

    FROM mimiciv_derived.sofa2_stage1_urine u
    WHERE u.hr BETWEEN 0 AND 23  -- 只看ICU入科后24小时
    AND u.stay_id IN (
        SELECT stay_id FROM (
            SELECT stay_id,
                   COUNT(*) as total_hours
            FROM mimiciv_derived.sofa2_stage1_urine
            WHERE hr BETWEEN 0 AND 23
            GROUP BY stay_id
            HAVING COUNT(*) > 20  -- 至少有21小时的数据
            ORDER BY total_hours DESC
            LIMIT 5
        ) t
    )
)
SELECT
    stay_id,
    AVG(weight) as avg_weight,
    AVG(cnt_6h) as avg_cnt_6h,
    AVG(cnt_12h) as avg_cnt_12h,
    AVG(cnt_24h) as avg_cnt_24h,
    AVG(uo_sum_6h) as avg_uo_6h,
    AVG(uo_sum_12h) as avg_uo_12h,
    AVG(uo_sum_24h) as avg_uo_24h,
    AVG(uo_rate_6h) as avg_rate_6h,
    AVG(uo_rate_12h) as avg_rate_12h,
    AVG(uo_rate_24h) as avg_rate_24h
FROM urine_debug
GROUP BY stay_id
ORDER BY stay_id;

-- 2. 检查具体的评分逻辑案例
WITH detailed_scoring AS (
    SELECT
        s.stay_id,
        s.hr,
        kl.creatinine,
        rr.on_rrt,
        u.weight,
        u.cnt_24h,
        u.uo_sum_24h,
        kl.potassium,
        kl.ph,
        kl.bicarbonate,

        -- 尿量速率计算
        CASE WHEN u.cnt_24h > 0 THEN u.uo_sum_24h / u.weight / u.cnt_24h ELSE NULL END as uo_rate_24h,

        -- SOFA2评分逻辑分解
        CASE WHEN rr.on_rrt = 1 THEN 4 ELSE 0 END as rrt_score,
        CASE
            WHEN kl.creatinine > 1.2 OR (u.uo_sum_24h / u.weight / NULLIF(u.cnt_24h, 0)) < 0.3
                 AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
            THEN 4
            ELSE 0
        END as virtual_rrt_score,
        CASE WHEN kl.creatinine > 3.5 THEN 3 ELSE 0 END as creatinine_score_3,
        CASE WHEN (u.uo_sum_24h / u.weight / NULLIF(u.cnt_24h, 0)) < 0.3 THEN 3 ELSE 0 END as urine_score_3,
        CASE WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3 ELSE 0 END as urine_absent_score_3,

        -- 最终评分
        GREATEST(
            CASE WHEN rr.on_rrt = 1 THEN 4 ELSE 0 END,
            CASE
                WHEN (kl.creatinine > 1.2 OR (u.uo_sum_24h / u.weight / NULLIF(u.cnt_24h, 0)) < 0.3)
                     AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
                THEN 4 ELSE 0
            END,
            CASE WHEN kl.creatinine > 3.5 THEN 3 ELSE 0 END,
            CASE WHEN (u.uo_sum_24h / u.weight / NULLIF(u.cnt_24h, 0)) < 0.3 THEN 3 ELSE 0 END,
            CASE WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3 ELSE 0 END,
            CASE WHEN kl.creatinine > 2.0 THEN 2 ELSE 0 END,
            CASE WHEN (u.uo_sum_12h / u.weight / NULLIF(u.cnt_12h, 0)) < 0.5 THEN 2 ELSE 0 END,
            CASE WHEN kl.creatinine > 1.2 THEN 1 ELSE 0 END,
            CASE WHEN (u.uo_sum_6h / u.weight / NULLIF(u.cnt_6h, 0)) < 0.5 THEN 1 ELSE 0 END
        ) as calculated_score

    FROM mimiciv_derived.sofa2_hourly_raw s
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON s.stay_id = kl.stay_id AND s.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON s.stay_id = rr.stay_id AND s.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON s.stay_id = u.stay_id AND s.hr = u.hr
    WHERE s.hr BETWEEN 0 AND 23
    AND s.stay_id IN (
        SELECT stay_id FROM (
            SELECT DISTINCT stay_id
            FROM mimiciv_derived.first_day_sofa2
            WHERE kidney = 3
            LIMIT 5
        ) t
    )
)
SELECT
    stay_id,
    AVG(calculated_score) as avg_calc_score,
    AVG(CASE WHEN creatinine_score_3 = 1 THEN 3 ELSE 0 END) as avg_creatinine_3_score,
    AVG(CASE WHEN urine_score_3 = 1 THEN 3 ELSE 0 END) as avg_urine_3_score,
    AVG(CASE WHEN urine_absent_score_3 = 1 THEN 3 ELSE 0 END) as avg_urine_absent_3_score,
    AVG(rrt_score) as avg_rrt_score,
    AVG(virtual_rrt_score) as avg_virtual_rrt_score,
    AVG(uo_rate_24h) as avg_urine_rate_24h
FROM detailed_scoring
GROUP BY stay_id
ORDER BY stay_id;