-- =================================================================
-- Gaps and Islands 算法验证演示
-- 展示连续时间 vs 累计时间的根本区别
-- =================================================================

WITH
-- 模拟测试数据：模拟一个患者的尿量模式
test_urine_data AS (
    SELECT 'TEST_PATIENT' as stay_id, 2 as hr, 0.4 as uo_ml_kg_hr UNION ALL  -- 低尿量 (第2小时)
    SELECT 'TEST_PATIENT', 3, 0.2 UNION ALL                                  -- 低尿量 (第3小时) - 连续第2小时
    SELECT 'TEST_PATIENT', 4, 1.2 UNION ALL                                  -- 正常尿量 (第4小时) - 中断
    SELECT 'TEST_PATIENT', 10, 0.3 UNION ALL                                 -- 低尿量 (第10小时) - 新的连续开始
    SELECT 'TEST_PATIENT', 11, 0.1 UNION ALL                                 -- 低尿量 (第11小时) - 连续第2小时
    SELECT 'TEST_PATIENT', 12, 0.0 UNION ALL                                 -- 无尿 (第12小时) - 连续第3小时
    SELECT 'TEST_PATIENT', 20, 0.4 UNION ALL                                 -- 低尿量 (第20小时) - 第3个连续段开始
    SELECT 'TEST_PATIENT', 21, 0.3                                           -- 低尿量 (第21小时) - 连续第2小时
),

-- 步骤1: 标记低尿量事件
flagged_data AS (
    SELECT
        stay_id,
        hr,
        uo_ml_kg_hr,
        CASE WHEN uo_ml_kg_hr < 0.5 THEN 1 ELSE 0 END as is_low_05
    FROM test_urine_data
),

-- 步骤2: Gaps and Islands - 为连续的相同值创建相同的组ID
islands_data AS (
    SELECT
        stay_id,
        hr,
        uo_ml_kg_hr,
        is_low_05,
        -- 核心算法：当连续的低尿量被打断时，组ID会跳跃
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, is_low_05 ORDER BY hr) as island_id
    FROM flagged_data
),

-- 步骤3: 计算连续时长
consecutive_calculation AS (
    SELECT
        stay_id,
        hr,
        uo_ml_kg_hr,
        is_low_05,
        island_id,
        -- 对于每个连续段，计算其长度
        COUNT(*) OVER (PARTITION BY stay_id, is_low_05, island_id) as consecutive_hours
    FROM islands_data
),

-- 步骤4: 旧的错误方法 (累计时间) - 用于对比
cumulative_calculation AS (
    SELECT
        stay_id,
        hr,
        uo_ml_kg_hr,
        is_low_05,
        -- 错误的累计方法：从开始到现在的总低尿量小时数
        SUM(is_low_05) OVER (PARTITION BY stay_id ORDER BY hr ROWS UNBOUNDED PRECEDING) as cumulative_hours
    FROM flagged_data
)

-- 验证结果对比
SELECT
    c.stay_id,
    c.hr,
    ROUND(c.uo_ml_kg_hr, 3) as urine_ml_per_kg_hr,
    c.is_low_05,
    c.consecutive_hours as correct_consecutive_hours,
    cum.cumulative_hours as wrong_cumulative_hours,
    CASE
        WHEN c.consecutive_hours >= 6 AND c.consecutive_hours < 12 THEN '1分(连续6-12h)'
        WHEN c.consecutive_hours >= 12 THEN '2分(连续≥12h)'
        WHEN c.is_low_05 = 1 THEN '低尿量但未评分'
        ELSE '正常尿量'
    END as correct_score,
    CASE
        WHEN cum.cumulative_hours >= 6 AND cum.cumulative_hours < 12 THEN '1分(累计6-12h)❌'
        WHEN cum.cumulative_hours >= 12 THEN '2分(累计≥12h)❌'
        WHEN cum.cumulative_hours > 0 THEN '累计低尿量❌'
        ELSE '正常'
    END as wrong_score,
    -- 验证说明
    CASE
        WHEN c.consecutive_hours != cum.cumulative_hours AND c.is_low_05 = 1
        THEN '✅ 修复成功：连续≠累计'
        WHEN c.is_low_05 = 0
        THEN '正常尿量'
        ELSE '检查数据'
    END as validation_result
FROM consecutive_calculation c
JOIN cumulative_calculation cum ON c.stay_id = cum.stay_id AND c.hr = cum.hr
WHERE c.is_low_05 = 1 OR cum.cumulative_hours > 0
ORDER BY c.hr;