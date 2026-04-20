-- Review Check #7: 镇静洗脱期敏感性分析
-- 比较: 当前实现(无洗脱) vs 加1h洗脱 对脑部评分的影响
-- 逻辑: 找出"镇静结束后1小时内"记录的GCS，看这些GCS是否被当作有效值

WITH sepsis_stays AS (
    SELECT DISTINCT stay_id FROM (
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa1_delta
        UNION
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa2_delta
    ) t
),

-- 镇静结束后 0-1h 内的 GCS 记录
-- 当前代码: 这些被视为"未镇静"的有效GCS (因为已经超过 endtime)
-- 加洗脱后: 这些应该被视为"仍在镇静影响下"
gcs_in_washout AS (
    SELECT
        g.stay_id,
        g.charttime AS gcs_time,
        g.gcs,
        s.endtime AS sedation_end,
        EXTRACT(EPOCH FROM (g.charttime - s.endtime)) / 60.0 AS minutes_after_sedation
    FROM mimiciv_derived.gcs g
    INNER JOIN sepsis_stays ss ON g.stay_id = ss.stay_id
    INNER JOIN mimiciv_derived.sofa2_stage1_sedation s
        ON g.stay_id = s.stay_id
        AND g.charttime > s.endtime                          -- 在镇静结束之后
        AND g.charttime <= s.endtime + INTERVAL '1 HOUR'     -- 但在1h洗脱期内
    -- 排除同时在另一段镇静中的记录
    WHERE NOT EXISTS (
        SELECT 1 FROM mimiciv_derived.sofa2_stage1_sedation s2
        WHERE g.stay_id = s2.stay_id
          AND g.charttime >= s2.starttime
          AND g.charttime <= s2.endtime
    )
)
SELECT
    'Part A: 洗脱期内GCS概况' AS label,
    COUNT(*) AS gcs_records_in_washout,
    COUNT(DISTINCT stay_id) AS stays_affected,
    ROUND(AVG(gcs)::numeric, 1) AS avg_gcs,
    ROUND(AVG(minutes_after_sedation)::numeric, 1) AS avg_minutes_after,
    -- GCS 分布
    SUM(CASE WHEN gcs = 15 THEN 1 ELSE 0 END) AS gcs_15,
    SUM(CASE WHEN gcs BETWEEN 13 AND 14 THEN 1 ELSE 0 END) AS gcs_13_14,
    SUM(CASE WHEN gcs BETWEEN 9 AND 12 THEN 1 ELSE 0 END) AS gcs_9_12,
    SUM(CASE WHEN gcs <= 8 THEN 1 ELSE 0 END) AS gcs_le8
FROM gcs_in_washout;
