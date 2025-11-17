-- =================================================================
-- 测试修复后的心血管系统（完整机械支持 + 性能优化）
-- =================================================================

-- 测试1: 验证机械支持覆盖情况
WITH test_stays AS (
    SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 20
),

mechanical_support_test AS (
    SELECT
        co.stay_id,
        co.hr,
        COALESCE(mech.has_ecmo, 0) AS has_ecmo,
        COALESCE(mech.has_iabp, 0) AS has_iabp,
        COALESCE(mech.has_impella, 0) AS has_impella,
        COALESCE(mech.has_lvad, 0) AS has_lvad,
        -- 机械支持总分
        COALESCE(mech.has_ecmo, 0) + COALESCE(mech.has_iabp, 0) +
        COALESCE(mech.has_impella, 0) + COALESCE(mech.has_lvad, 0) AS total_mechanical_support
    FROM test_stays co
    INNER JOIN mimiciv_derived.icustay_hourly ih
        ON co.stay_id = ih.stay_id
        AND ih.hr BETWEEN 0 AND 24
    -- 复制优化后的机械支持逻辑
    LEFT JOIN (
        SELECT
            ih.stay_id,
            ih.hr,
            MAX(CASE WHEN ce.itemid IN (
                -- ECMO相关itemid (基于实际数据验证)
                224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
                229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
                228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
            ) THEN 1 ELSE 0 END) AS has_ecmo,
            MAX(CASE WHEN ce.itemid IN (
                -- IABP相关itemid (基于实际数据验证)
                224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986,
                225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355,
                225742
            ) THEN 1 ELSE 0 END) AS has_iabp,
            MAX(CASE WHEN ce.itemid IN (
                -- Impella相关itemid (基于实际数据验证)
                228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671,
                228171, 228172, 227355, 228167, 228170, 224314, 224318, 229898
            ) THEN 1 ELSE 0 END) AS has_impella,
            MAX(CASE WHEN ce.itemid IN (
                -- LVAD相关itemid (基于实际数据验证)
                229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 220128
            ) THEN 1 ELSE 0 END) AS has_lvad
        FROM mimiciv_derived.icustay_hourly ih
        LEFT JOIN mimiciv_icu.chartevents ce
            ON ih.stay_id = ce.stay_id
            AND ce.charttime >= ih.endtime - INTERVAL '1 HOUR'
            AND ce.charttime < ih.endtime
            AND ce.itemid IN (
                -- 完整的机械支持itemid列表
                224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
                229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
                228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260,
                224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986,
                225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355,
                225742, 228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897,
                229671, 228171, 228172, 227355, 228167, 228170, 224314, 224318, 229898,
                220128
            )
        WHERE ih.stay_id IN (SELECT stay_id FROM test_stays)
        GROUP BY ih.stay_id, ih.hr
    ) mech ON ih.stay_id = mech.stay_id AND ih.hr = mech.hr
)

-- 显示机械支持检测结果
SELECT
    stay_id,
    hr,
    has_ecmo,
    has_iabp,
    has_impella,
    has_lvad,
    total_mechanical_support,
    CASE WHEN total_mechanical_support > 0 THEN 'MCS Detected' ELSE 'No MCS' END AS mcs_status
FROM mechanical_support_test
WHERE total_mechanical_support > 0
ORDER BY stay_id, hr
LIMIT 20;

-- 测试2: 性能对比（小样本）
-- 使用优化后的预聚合方法 vs 原始LATERAL方法
-- 这里我们只展示优化方法的执行计划

EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT
    co.stay_id,
    co.hr,
    COUNT(*) as record_count,
    -- 简化的机械支持检测
    SUM(CASE WHEN ce.itemid IN (224660, 224322, 228154, 220128) THEN 1 ELSE 0 END) AS any_mechanical_support
FROM mimiciv_derived.icustay_hourly co
LEFT JOIN mimiciv_icu.chartevents ce
    ON co.stay_id = ce.stay_id
    AND ce.charttime >= co.endtime - INTERVAL '1 HOUR'
    AND ce.charttime < co.endtime
    AND ce.itemid IN (224660, 224322, 228154, 220128)
WHERE co.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 100)
    AND co.hr BETWEEN 0 AND 24
GROUP BY co.stay_id, co.hr
ORDER BY co.stay_id, co.hr;