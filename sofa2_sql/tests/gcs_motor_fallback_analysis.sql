-- GCS运动域替代逻辑必要性分析
-- 比较当前逻辑 vs 添加运动域替代后的覆盖度差异

-- =================================================================
-- 当前的GCS逻辑（仅使用完整GCS）
-- =================================================================
WITH hourly_sample AS (
    -- 取样前100个ICU住院的前24小时
    SELECT stay_id, intime, outtime,
           generate_series(0, 23) as hr
    FROM mimiciv_icu.icustays
    WHERE stay_id IN (SELECT stay_id FROM mimiciv_icu.icustays ORDER BY stay_id LIMIT 100)
),

-- 当前逻辑：只查找完整GCS
current_logic AS (
    SELECT
        ht.stay_id,
        ht.hr,
        ht.intime + INTERVAL '1 hour' * ht.hr as hour_start,
        ht.intime + INTERVAL '1 hour' * (ht.hr + 1) as hour_end,
        gcs.gcs,
        gcs.gcs_motor,
        gcs.charttime as gcs_time,
        CASE
            WHEN gcs.gcs IS NOT NULL THEN 'Complete GCS available'
            WHEN gcs.gcs_motor IS NOT NULL THEN 'Only motor available (unused)'
            ELSE 'No GCS data'
        END as current_status
    FROM hourly_sample ht
    LEFT JOIN LATERAL (
        SELECT gcs.gcs, gcs.gcs_motor, gcs.charttime
        FROM mimiciv_derived.gcs gcs
        WHERE gcs.stay_id = ht.stay_id
          AND gcs.charttime <= ht.intime + INTERVAL '1 hour' * (ht.hr + 1)
        ORDER BY gcs.charttime DESC
        LIMIT 1
    ) gcs ON TRUE
),

-- 改进逻辑：完整GCS + 运动域回退
improved_logic AS (
    SELECT
        ht.stay_id,
        ht.hr,
        -- 第一优先级：完整GCS
        COALESCE(
            (SELECT gcs.gcs
             FROM mimiciv_derived.gcs gcs
             WHERE gcs.stay_id = ht.stay_id
               AND gcs.charttime <= ht.intime + INTERVAL '1 hour' * (ht.hr + 1)
               AND gcs.gcs IS NOT NULL
             ORDER BY gcs.charttime DESC
             LIMIT 1),
            -- 第二优先级：运动域（转换为近似GCS）
            (SELECT CASE
                    WHEN gcs.gcs_motor = 6 THEN 15  -- 遵从命令
                    WHEN gcs.gcs_motor = 5 THEN 14  -- 定位痛
                    WHEN gcs.gcs_motor = 4 THEN 12  -- 退缩痛
                    WHEN gcs.gcs_motor = 3 THEN 9   -- 屈曲痛
                    WHEN gcs.gcs_motor = 2 THEN 6   -- 伸展痛
                    WHEN gcs.gcs_motor = 1 THEN 3   -- 无反应
                    ELSE NULL
                 END
             FROM mimiciv_derived.gcs gcs
             WHERE gcs.stay_id = ht.stay_id
               AND gcs.charttime <= ht.intime + INTERVAL '1 hour' * (ht.hr + 1)
               AND gcs.gcs_motor IS NOT NULL
               AND gcs.gcs IS NULL  -- 确保只在没有完整GCS时使用
             ORDER BY gcs.charttime DESC
             LIMIT 1)
        ) as fallback_gcs_score,
        -- 标记数据来源
        CASE
            WHEN EXISTS (
                SELECT 1 FROM mimiciv_derived.gcs gcs
                WHERE gcs.stay_id = ht.stay_id
                  AND gcs.charttime <= ht.intime + INTERVAL '1 hour' * (ht.hr + 1)
                  AND gcs.gcs IS NOT NULL
                LIMIT 1
            ) THEN 'Complete GCS used'
            WHEN EXISTS (
                SELECT 1 FROM mimiciv_derived.gcs gcs
                WHERE gcs.stay_id = ht.stay_id
                  AND gcs.charttime <= ht.intime + INTERVAL '1 hour' * (ht.hr + 1)
                  AND gcs.gcs_motor IS NOT NULL
                  AND gcs.gcs IS NULL
                LIMIT 1
            ) THEN 'Motor fallback used'
            ELSE 'No GCS data'
        END as improved_status
    FROM hourly_sample ht
),

-- 覆盖度对比分析
coverage_comparison AS (
    SELECT
        'Coverage Comparison' as analysis_type,
        COUNT(*) as total_hours,
        -- 当前逻辑覆盖度
        COUNT(CASE WHEN cl.current_status = 'Complete GCS available' THEN 1 END) as current_with_gcs,
        ROUND(COUNT(CASE WHEN cl.current_status = 'Complete GCS available' THEN 1 END) * 100.0 / COUNT(*), 2) as current_coverage_pct,
        -- 改进逻辑覆盖度
        COUNT(CASE WHEN il.improved_status IN ('Complete GCS used', 'Motor fallback used') THEN 1 END) as improved_with_gcs,
        ROUND(COUNT(CASE WHEN il.improved_status IN ('Complete GCS used', 'Motor fallback used') THEN 1 END) * 100.0 / COUNT(*), 2) as improved_coverage_pct,
        -- 净提升
        COUNT(CASE WHEN il.improved_status = 'Motor fallback used' THEN 1 END) as additional_hours_covered,
        ROUND(COUNT(CASE WHEN il.improved_status = 'Motor fallback used' THEN 1 END) * 100.0 / COUNT(*), 2) as improvement_pct
    FROM current_logic cl
    JOIN improved_logic il ON cl.stay_id = il.stay_id AND cl.hr = il.hr
)

SELECT * FROM coverage_comparison

UNION ALL

-- 详细的缺失模式分析
SELECT
    'Missing Pattern Details' as analysis_type,
    cl.current_status as pattern,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM current_logic), 2) as pct,
    NULL as total_hours,
    NULL as current_with_gcs,
    NULL as current_coverage_pct,
    NULL as improved_with_gcs,
    NULL as improved_coverage_pct,
    NULL as additional_hours_covered,
    NULL as improvement_pct
FROM current_logic cl
GROUP BY cl.current_status

UNION ALL

-- 改进后的详细状态
SELECT
    'Improved Logic Details' as analysis_type,
    il.improved_status as pattern,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM improved_logic), 2) as pct,
    NULL as total_hours,
    NULL as current_with_gcs,
    NULL as current_coverage_pct,
    NULL as improved_with_gcs,
    NULL as improved_coverage_pct,
    NULL as additional_hours_covered,
    NULL as improvement_pct
FROM improved_logic il
GROUP BY il.improved_status

UNION ALL

-- 运动域与完整GCS的差异分析（当两者都可用时）
SELECT
    'Motor vs Complete GCS Difference' as analysis_type,
    'Hours with both data' as pattern,
    COUNT(*) as count,
    ROUND(AVG(gcs_difference), 2) as avg_gcs_difference,
    NULL as total_hours,
    NULL as current_with_gcs,
    NULL as current_coverage_pct,
    NULL as improved_with_gcs,
    NULL as improved_coverage_pct,
    NULL as additional_hours_covered,
    NULL as improvement_pct
FROM (
    SELECT
        cl.stay_id,
        cl.hr,
        ABS(cl.gcs -
            CASE cl.gcs_motor
                WHEN 6 THEN 15
                WHEN 5 THEN 14
                WHEN 4 THEN 12
                WHEN 3 THEN 9
                WHEN 2 THEN 6
                WHEN 1 THEN 3
                ELSE NULL
            END
        ) as gcs_difference
    FROM current_logic cl
    WHERE cl.gcs IS NOT NULL
      AND cl.gcs_motor IS NOT NULL
) diff_analysis

ORDER BY analysis_type, pattern;