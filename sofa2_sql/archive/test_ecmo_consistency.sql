-- =================================================================
-- 测试呼吸系统和循环系统ECMO定义的一致性
-- =================================================================

-- 测试患者：检查已知有ECMO的患者
WITH test_ecmo_patients AS (
    -- 查找有ECMO相关记录的患者
    SELECT DISTINCT stay_id
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (229270, 229272, 229268)  -- 使用高频ECMO itemid
    LIMIT 10
),

-- 呼吸系统ECMO检测（修复后的逻辑）
WITH respiratory_ecmo AS (
    SELECT
        co.stay_id,
        co.hr,
        co.endtime - INTERVAL '1 HOUR' as starttime,
        co.endtime,
        COUNT(CASE WHEN ce.itemid IN (
            -- 修复后的ECMO相关itemid（与循环系统一致）
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
        ) THEN 1 END) AS ecmo_events_respiratory
    FROM test_ecmo_patients p
    INNER JOIN mimiciv_derived.icustay_hourly co ON p.stay_id = co.stay_id AND co.hr BETWEEN 0 AND 24
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
        AND ce.charttime >= (co.endtime - INTERVAL '1 HOUR')
        AND ce.charttime < co.endtime
        AND ce.itemid IN (
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
        )
    GROUP BY co.stay_id, co.hr, co.endtime
),

-- 循环系统ECMO检测（当前的逻辑）
cardiovascular_ecmo AS (
    SELECT
        co.stay_id,
        co.hr,
        co.endtime - INTERVAL '1 HOUR' as starttime,
        co.endtime,
        MAX(CASE WHEN ce.itemid IN (
            -- 循环系统的ECMO相关itemid
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
        ) THEN 1 ELSE 0 END) AS ecmo_events_cardiovascular
    FROM test_ecmo_patients p
    INNER JOIN mimiciv_derived.icustay_hourly co ON p.stay_id = co.stay_id AND co.hr BETWEEN 0 AND 24
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
        AND ce.charttime >= (co.endtime - INTERVAL '1 HOUR')
        AND ce.charttime < co.endtime
        AND ce.itemid IN (
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
        )
    GROUP BY co.stay_id, co.hr, co.endtime
)

-- 比较两个系统的ECMO检测结果
SELECT
    r.stay_id,
    r.hr,
    r.ecmo_events_respiratory > 0 AS respiratory_detects_ecmo,
    c.ecmo_events_cardiovascular AS cardiovascular_detects_ecmo,
    CASE
        WHEN (r.ecmo_events_respiratory > 0) = (c.ecmo_events_cardiovascular > 0)
        THEN 'CONSISTENT'
        ELSE 'INCONSISTENT'
    END AS consistency_check,
    r.ecmo_events_respiratory,
    c.ecmo_events_cardiovascular
FROM respiratory_ecmo r
JOIN cardiovascular_ecmo c ON r.stay_id = c.stay_id AND r.hr = c.hr
ORDER BY r.stay_id, r.hr
LIMIT 20;

-- 统计一致性
WITH consistency_stats AS (
    SELECT
        COUNT(*) as total_hours,
        SUM(CASE WHEN (r.ecmo_events_respiratory > 0) = (c.ecmo_events_cardiovascular > 0) THEN 1 ELSE 0 END) as consistent_hours,
        SUM(CASE WHEN r.ecmo_events_respiratory > 0 THEN 1 ELSE 0 END) as respiratory_ecmo_hours,
        SUM(CASE WHEN c.ecmo_events_cardiovascular > 0 THEN 1 ELSE 0 END) as cardiovascular_ecmo_hours
    FROM respiratory_ecmo r
    JOIN cardiovascular_ecmo c ON r.stay_id = c.stay_id AND r.hr = c.hr
)
SELECT
    total_hours,
    consistent_hours,
    ROUND(100.0 * consistent_hours / total_hours, 2) as consistency_percentage,
    respiratory_ecmo_hours,
    cardiovascular_ecmo_hours
FROM consistency_stats;