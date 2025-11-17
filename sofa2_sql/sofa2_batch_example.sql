-- SOFA-2 分批处理示例 - 按患者分批
-- =================================================================

-- 方法1: 使用患者ID范围分批
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 24
        -- 分批条件1: 按stay_id范围分批
        AND ih.stay_id BETWEEN 300000 AND 300100  -- 每批100个患者
        -- 或分批条件2: 按subject_id范围分批
        -- AND ie.subject_id BETWEEN 100000 AND 100200
        -- 或分批条件3: 使用LIMIT和OFFSET
        -- AND ih.stay_id IN (
        --     SELECT stay_id FROM mimiciv_derived.icustay_hourly
        --     ORDER BY stay_id
        --     LIMIT 100 OFFSET 0  -- 第一批: 0-99, 第二批: 100-199, 等等
        -- )
)

-- 其余CTE保持不变...
-- [这里复制原代码的所有其他CTE]

-- 最终输出添加批次标识
SELECT
    'BATCH_1' as batch_id,  -- 每批修改这个标识
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
ORDER BY stay_id, hr;