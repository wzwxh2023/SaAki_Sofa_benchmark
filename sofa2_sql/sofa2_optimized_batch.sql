-- SOFA-2 优化分批处理版本
-- =================================================================

-- 首先确定您的批次参数
-- 方法1: 使用特定的患者列表
WITH target_stays AS (
    SELECT stay_id FROM mimiciv_derived.icustay_hourly
    WHERE hr BETWEEN 0 AND 24
    AND stay_id IN (
        -- 在这里添加您要处理的具体stay_id
        -- 示例：
        -- 300001, 300002, 300003, 300004, 300005,
        -- 300006, 300007, 300008, 300009, 300010
        SELECT stay_id FROM mimiciv_derived.icustay_hourly
        WHERE stay_id BETWEEN 300000 AND 300100  -- 灵活调整范围
        LIMIT 50  -- 控制批次大小
    )
)

-- 基础时间窗口CTE（仅处理目标患者）
, co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    INNER JOIN target_stays ts
        ON ih.stay_id = ts.stay_id
    WHERE ih.hr BETWEEN 0 AND 24
)

-- 添加进度监控CTE
, progress_monitor AS (
    SELECT
        COUNT(DISTINCT stay_id) as total_stays_in_batch,
        MIN(stay_id) as min_stay_id,
        MAX(stay_id) as max_stay_id
    FROM co
)

-- [复制原代码的所有其他CTE，从sedation_detection开始]

-- 最终输出添加进度信息
SELECT
    CONCAT('BATCH_', MIN(stay_id), '_', MAX(stay_id)) as batch_range,
    COUNT(*) as total_records,
    COUNT(DISTINCT stay_id) as unique_patients,
    AVG(sofa2_total) as avg_sofa2,
    MAX(sofa2_total) as max_sofa2,
    MIN(sofa2_total) as min_sofa2
FROM (
    -- 这里放入原查询的最终SELECT部分
    SELECT
        stay_id,
        hadm_id,
        subject_id,
        hr,
        starttime,
        endtime,
        ratio_type,
        oxygen_ratio,
        has_advanced_support,
        on_ecmo,
        brain,
        respiratory,
        cardiovascular,
        liver,
        kidney,
        hemostasis,
        (COALESCE(brain, 0) + COALESCE(respiratory, 0) + COALESCE(cardiovascular, 0) +
         COALESCE(liver, 0) + COALESCE(kidney, 0) + COALESCE(hemostasis, 0)) AS sofa2_total
    FROM scorecomp
    WHERE hr >= 0
) final_results
GROUP BY batch_range
ORDER BY batch_range;