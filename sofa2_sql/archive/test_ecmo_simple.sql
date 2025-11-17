-- =================================================================
-- 简化测试：验证ECMO定义一致性
-- =================================================================

-- 测试1: 找一个已知有ECMO的患者
WITH ecmo_patient AS (
    SELECT DISTINCT stay_id
    FROM mimiciv_icu.chartevents
    WHERE itemid = 229270  -- Flow (ECMO)
    LIMIT 1
)

-- 测试2: 比较修复前后ECMO检测数量
SELECT
    p.stay_id,

    -- 修复前：只检查itemid=224660
    COUNT(CASE WHEN ce.itemid = 224660 THEN 1 END) as ecmo_count_before,

    -- 修复后：检查完整ECMO itemid列表
    COUNT(CASE WHEN ce.itemid IN (
        224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
        229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
        228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
    ) THEN 1 END) as ecmo_count_after,

    -- 改进倍数
    ROUND(
        COUNT(CASE WHEN ce.itemid IN (
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
        ) THEN 1 END)::numeric /
        NULLIF(COUNT(CASE WHEN ce.itemid = 224660 THEN 1 END), 0), 2
    ) as improvement_factor

FROM ecmo_patient p
INNER JOIN mimiciv_derived.icustay_hourly co ON p.stay_id = co.stay_id AND co.hr BETWEEN 0 AND 24
LEFT JOIN mimiciv_icu.chartevents ce
    ON co.stay_id = ce.stay_id
    AND ce.charttime >= (co.endtime - INTERVAL '1 HOUR')
    AND ce.charttime < co.endtime
    AND ce.itemid IN (
        224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
        229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
        228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 224660
    )
GROUP BY p.stay_id;