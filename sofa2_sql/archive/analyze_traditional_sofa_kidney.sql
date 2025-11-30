-- =================================================================
-- 分析传统SOFA肾脏评分计算逻辑（基于MIMIC官方实现）
-- =================================================================

-- 传统SOFA评分标准（肾脏）：
-- Cr ≤ 1.2 mg/dL 且 UO ≥ 0.5 mL/kg/h = 0分
-- Cr 1.2-1.9 mg/dL 或 UO < 0.5 mL/kg/h = 1分
-- Cr 2.0-3.4 mg/dL 或 UO < 0.5 mL/kg/h × 24h = 2分
-- Cr 3.5-4.9 mg/dL 或 UO < 0.3 mL/kg/h × 24h 或 anuria × 12h = 3分
-- Cr > 5.0 mg/dL 或 UO < 0.3 mL/kg/h × 24h 或 anuria × 12h = 4分
-- OR RRT = 4分

-- 1. 检查传统SOFA肾脏评分实现逻辑
WITH first_day_urine AS (
    -- 计算ICU入科后24小时内的总尿量
    SELECT
        ie.stay_id,
        SUM(uo.urineoutput) AS total_urine_24h,
        -- 需要体重信息，假设使用平均体重
        AVG(wd.weight) AS avg_weight
    FROM mimiciv_icu.icustays ie
    JOIN mimiciv_derived.urine_output uo
        ON ie.stay_id = uo.stay_id
        AND uo.charttime >= ie.intime
        AND uo.charttime < ie.intime + INTERVAL '24 hours'
    LEFT JOIN mimiciv_derived.weight_durations wd
        ON ie.stay_id = wd.stay_id
        AND uo.charttime >= wd.starttime
        AND uo.charttime <= wd.endtime
    GROUP BY ie.stay_id
),
creatinine_first_day AS (
    -- 获取ICU入科后24小时内的最高肌酐值
    SELECT
        ie.stay_id,
        MAX(CASE WHEN le.valuenum > 0 THEN le.valuenum END) AS max_creatinine
    FROM mimiciv_icu.icustays ie
    JOIN mimiciv_hosp.labevents le
        ON ie.hadm_id = le.hadm_id
        AND le.charttime >= ie.intime
        AND le.charttime < ie.intime + INTERVAL '24 hours'
        AND le.itemid = 50912  -- 肌酐
    GROUP BY ie.stay_id
),
traditional_sofa_kidney_calc AS (
    -- 计算传统SOFA肾脏评分
    SELECT
        fdu.stay_id,
        fdu.total_urine_24h,
        fdu.avg_weight,
        cfd.max_creatinine,
        -- 计算尿量速率 ml/kg/hr
        CASE WHEN fdu.avg_weight > 0
             THEN fdu.total_urine_24h / fdu.avg_weight / 24
             ELSE NULL END AS urine_rate_24h,

        -- RRT状态
        CASE WHEN EXISTS (
            SELECT 1 FROM mimiciv_derived.rrt r
            WHERE r.stay_id = fdu.stay_id
            AND r.charttime >= (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fdu.stay_id)
            AND r.charttime < (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fdu.stay_id) + INTERVAL '24 hours'
            AND r.dialysis_active = 1
        ) THEN 1 ELSE 0 END AS on_rrt_24h,

        -- 传统SOFA评分逻辑
        CASE WHEN EXISTS (
            SELECT 1 FROM mimiciv_derived.rrt r
            WHERE r.stay_id = fdu.stay_id
            AND r.charttime >= (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fdu.stay_id)
            AND r.charttime < (SELECT intime FROM mimiciv_icu.icustays WHERE stay_id = fdu.stay_id) + INTERVAL '24 hours'
            AND r.dialysis_active = 1
        ) THEN 4
        WHEN cfd.max_creatinine >= 5.0 THEN 4
        WHEN cfd.max_creatinine >= 3.5 OR
             (fdu.avg_weight > 0 AND fdu.total_urine_24h / fdu.avg_weight / 24 < 0.3) THEN 3
        WHEN cfd.max_creatinine >= 2.0 OR
             (fdu.avg_weight > 0 AND fdu.total_urine_24h / fdu.avg_weight / 24 < 0.5) THEN 2
        WHEN cfd.max_creatinine >= 1.2 OR
             (fdu.avg_weight > 0 AND fdu.total_urine_24h / fdu.avg_weight / 24 < 0.5) THEN 1
        ELSE 0 END AS calculated_traditional_score
    FROM first_day_urine fdu
    LEFT JOIN creatinine_first_day cfd ON fdu.stay_id = cfd.stay_id
)
-- 比较计算结果与实际存储的值
SELECT
    tsk.stay_id,
    tsk.calculated_traditional_score,
    fs.renal as official_sofa_renal,
    tsk.total_urine_24h,
    tsk.avg_weight,
    tsk.urine_rate_24h,
    tsk.max_creatinine,
    tsk.on_rrt_24h,
    CASE WHEN tsk.calculated_traditional_score = fs.renal THEN 'Match' ELSE 'Mismatch' END as validation
FROM traditional_sofa_kidney_calc tsk
JOIN mimiciv_derived.first_day_sofa fs ON tsk.stay_id = fs.stay_id
WHERE fs.renal IS NOT NULL
LIMIT 20;

-- 2. 分析SOFA2评分的关键差异点
WITH sofa2_kidney_detailed AS (
    SELECT
        hr.stay_id,
        hr.hr,
        kl.creatinine,
        rr.on_rrt,
        u.weight,
        u.cnt_24h,
        u.uo_sum_24h,

        -- SOFA2评分逻辑分解
        CASE
            WHEN rr.on_rrt = 1 THEN 4
            WHEN kl.creatinine > 1.2 OR (u.uo_sum_24h / u.weight / NULLIF(u.cnt_24h, 0)) < 0.3
                 AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
            THEN 4
            WHEN kl.creatinine > 3.5 THEN 3
            WHEN (u.uo_sum_24h / u.weight / NULLIF(u.cnt_24h, 0)) < 0.3 THEN 3
            WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3
            WHEN kl.creatinine > 2.0 THEN 2
            WHEN (u.uo_sum_12h / u.weight / NULLIF(u.cnt_12h, 0)) < 0.5 THEN 2
            WHEN kl.creatinine > 1.2 THEN 1
            WHEN (u.uo_sum_6h / u.weight / NULLIF(u.cnt_6h, 0)) < 0.5 THEN 1
            ELSE 0
        END as sofa2_kidney_score
    FROM mimiciv_derived.sofa2_hourly_raw hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl
        ON hr.stay_id = kl.stay_id AND hr.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr
        ON hr.stay_id = rr.stay_id AND hr.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u
        ON hr.stay_id = u.stay_id AND hr.hr = u.hr
    WHERE hr.hr BETWEEN 0 AND 23
)
-- 统计每个评分条件的触发次数
SELECT
    'SOFA2 Kidney Score Distribution' as analysis_type,
    sofa2_kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM sofa2_kidney_detailed
WHERE sofa2_kidney_score IS NOT NULL
GROUP BY sofa2_kidney_score
ORDER BY sofa2_kidney_score;