-- =================================================================
-- 测试循环系统修复后的逻辑
-- =================================================================

-- 测试1: 验证血管活性药物表结构
SELECT
    stay_id,
    starttime,
    endtime,
    norepinephrine,
    epinephrine,
    dopamine,
    dobutamine,
    vasopressin,
    phenylephrine,
    milrinone
FROM mimiciv_derived.vasoactive_agent
WHERE stay_id IN (
    SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 5
)
LIMIT 10;

-- 测试2: 验证修改后的心血管评分逻辑（小样本）
WITH test_co AS (
    SELECT
        stay_id,
        hr,
        endtime - INTERVAL '1 HOUR' AS starttime,
        endtime
    FROM mimiciv_derived.icustay_hourly
    WHERE stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 10)
),

test_vasoactive AS (
    SELECT
        test_co.stay_id,
        test_co.hr,
        -- NE/Epi总碱基剂量计算
        (COALESCE(MAX(va.norepinephrine), 0) / 2.0 + COALESCE(MAX(va.epinephrine), 0)) AS ne_epi_total_base_dose,
        -- 其他药物标志
        CASE WHEN COALESCE(MAX(va.dopamine), 0) > 0
              OR COALESCE(MAX(va.dobutamine), 0) > 0
              OR COALESCE(MAX(va.vasopressin), 0) > 0
              OR COALESCE(MAX(va.phenylephrine), 0) > 0
              OR COALESCE(MAX(va.milrinone), 0) > 0
             THEN 1 ELSE 0
        END AS any_other_agent_flag,
        -- 原始剂量用于对比
        MAX(va.norepinephrine) as rate_norepinephrine_raw,
        MAX(va.epinephrine) as rate_epinephrine_raw,
        MAX(va.dopamine) as rate_dopamine_raw,
        MAX(va.dobutamine) as rate_dobutamine_raw
    FROM test_co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON test_co.stay_id = va.stay_id
        AND va.starttime < test_co.endtime
        AND COALESCE(va.endtime, test_co.endtime) > test_co.starttime
    GROUP BY test_co.stay_id, test_co.hr
)

-- 显示计算结果
SELECT
    stay_id,
    hr,
    ne_epi_total_base_dose,
    any_other_agent_flag,
    rate_norepinephrine_raw,
    rate_epinephrine_raw,
    rate_dopamine_raw,
    rate_dobutamine_raw,
    -- 根据新逻辑计算的心血管评分
    CASE
        -- 4分条件
        WHEN ne_epi_total_base_dose > 0.4 THEN 4
        WHEN ne_epi_total_base_dose > 0.2 AND any_other_agent_flag = 1 THEN 4
        -- 3分条件
        WHEN ne_epi_total_base_dose > 0.2 THEN 3
        WHEN ne_epi_total_base_dose > 0 AND any_other_agent_flag = 1 THEN 3
        -- 2分条件
        WHEN ne_epi_total_base_dose > 0 THEN 2
        WHEN any_other_agent_flag = 1 THEN 2
        -- 1分和0分需要MAP数据，暂时设为0
        ELSE 0
    END AS calculated_cardiovascular_score
FROM test_vasoactive
WHERE ne_epi_total_base_dose > 0 OR any_other_agent_flag = 1
ORDER BY stay_id, hr;