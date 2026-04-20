-- Review Check #7 v2: 洗脱期GCS分布对比
WITH sedation AS (
    SELECT stay_id, starttime, endtime
    FROM mimiciv_icu.inputevents
    WHERE itemid IN (222168, 221668, 229420, 225150, 221385, 221712, 221756, 225156)
      AND amount > 0
),
next_gcs AS (
    SELECT
        se.stay_id,
        se.endtime AS sed_end,
        g.charttime,
        g.gcs,
        EXTRACT(EPOCH FROM (g.charttime - se.endtime)) / 3600.0 AS hours_gap,
        ROW_NUMBER() OVER (PARTITION BY se.stay_id, se.endtime ORDER BY g.charttime) AS rn
    FROM sedation se
    INNER JOIN mimiciv_derived.gcs g
        ON se.stay_id = g.stay_id
        AND g.charttime > se.endtime
        AND g.charttime <= se.endtime + INTERVAL '8 HOUR'
    -- 排除此GCS仍在另一段镇静中
    WHERE NOT EXISTS (
        SELECT 1 FROM sedation s2
        WHERE g.stay_id = s2.stay_id
          AND g.charttime >= s2.starttime AND g.charttime <= s2.endtime
    )
)
SELECT
    CASE WHEN hours_gap <= 1 THEN 'In washout (0-1h)' ELSE 'After washout (>1h)' END AS period,
    COUNT(*) AS n,
    ROUND(AVG(gcs)::numeric, 1) AS avg_gcs,
    SUM(CASE WHEN gcs = 15 THEN 1 ELSE 0 END) AS gcs_15,
    SUM(CASE WHEN gcs BETWEEN 13 AND 14 THEN 1 ELSE 0 END) AS gcs_13_14,
    SUM(CASE WHEN gcs BETWEEN 9 AND 12 THEN 1 ELSE 0 END) AS gcs_9_12,
    SUM(CASE WHEN gcs BETWEEN 3 AND 8 THEN 1 ELSE 0 END) AS gcs_3_8,
    ROUND(100.0 * SUM(CASE WHEN gcs <= 12 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_abnormal
FROM next_gcs
WHERE rn = 1
GROUP BY 1
ORDER BY 1;
