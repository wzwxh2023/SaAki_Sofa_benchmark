-- =================================================================
-- SOFA-2肾脏评分改进方案 - 适应性评分策略
-- 解决因数据不足导致的评分偏差问题
--
-- 主要改进：
-- 1. 放宽完整数据要求，支持部分数据评估
-- 2. 添加数据完整性标记
-- 3. 实现分层评分策略
-- 4. 保持临床合理性
-- =================================================================

-- 首先检查当前数据缺失情况
SELECT
    '=== SOFA-2肾脏评分数据现状分析 ===' as report_title,
    '' as stay_id, '' as icu_los_hours, '' as total_measurements,
    '' as urine_data_hours, '' as cnt_24h_max, '' as data_completeness,
    '' as current_kidney_score, '' as notes,
    NULL as sort_order

UNION ALL

SELECT
    '数据分布统计',
    '', '', '', '', '', '', '', 1 as sort_order
UNION ALL

SELECT
    '总患者数',
    CAST(COUNT(*) AS VARCHAR),
    '', '', '', '', '', 2
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    'ICU住院>24h患者',
    CAST(COUNT(CASE WHEN icu_los_hours >= 24 THEN 1 END) AS VARCHAR),
    '', '', '', '', '', 3
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '完整24小时尿量数据患者',
    CAST(COUNT(CASE WHEN total_measurements >= 24 THEN 1 END) AS VARCHAR),
    '', '', '', '', '', 4
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '不完整数据患者比例',
    CAST(ROUND(COUNT(CASE WHEN total_measurements < 24 THEN 1 END) * 100.0 / COUNT(*), 2) AS VARCHAR) || '%',
    '', '', '', '', '', 5
FROM mimiciv_derived.first_day_sofa2

UNION ALL

SELECT
    '=== 典型患者案例分析 ===',
    '', '', '', '', '', '', '', 6
UNION ALL

SELECT
    '患者39553978 (问题案例)',
    CAST(icu_los_hours AS VARCHAR),
    CAST(total_measurements AS VARCHAR),
    '', '', '', '', 7
FROM mimiciv_derived.first_day_sofa2
WHERE stay_id = 39553978

UNION ALL

SELECT
    '该患者当前肾脏评分',
    '', '', '', '', '', CAST(kidney AS VARCHAR), '当前实现：因数据不足直接评为0分', 8
FROM mimiciv_derived.first_day_sofa2
WHERE stay_id = 39553978

UNION ALL

SELECT
    '=== 改进方案设计 ===',
    '', '', '', '', '', '', '', 9
UNION ALL

SELECT
    '适应性评分策略',
    '', '', '', '', '', '', '根据数据可用性调整评分标准', 10
UNION ALL

SELECT
    '分层评估方法',
    '', '', '', '', '', '', '6h/12h/24h数据分别对应不同评分阈值', 11

UNION ALL

SELECT
    '临床合理性检查',
    '', '', '', '', '', '', '确保改进后的评分符合临床逻辑', 12

ORDER BY sort_order;

-- 改进的SOFA-2肾脏评分逻辑
--
-- 设计原则：
-- 1. 当有24小时数据时，使用原标准
-- 2. 当只有12小时数据时，调整阈值并标记
-- 3. 当只有6小时数据时，进一步调整阈值并标记
-- 4. 当数据极少时，依赖肌酐评分并标记数据不足
-- 5. 始终标记数据完整性，供后续分析使用

/*
改进的肾脏评分伪代码：

CASE
    -- RRT患者（最高优先级）
    WHEN has_rrt THEN 4

    -- 复杂RRT标准（电解质紊乱+肌酐升高）
    WHEN (creatinine > 1.2 AND has_electrolyte_crisis) THEN 4

    -- 24小时完整数据评估
    WHEN cnt_24h >= 20 AND urine_rate_24h < 0.3 THEN 3
    WHEN cnt_24h >= 20 AND urine_rate_24h < 0.5 THEN 2

    -- 12小时数据评估（调整阈值）
    WHEN cnt_12h >= 8 AND urine_rate_12h < 0.25 THEN 3  -- 更严格
    WHEN cnt_12h >= 8 AND urine_rate_12h < 0.4 THEN 2   -- 更严格

    -- 6小时数据评估（进一步调整阈值）
    WHEN cnt_6h >= 4 AND urine_rate_6h < 0.2 THEN 2     -- 保守评分

    -- 肌酐评估（始终可用）
    WHEN creatinine > 3.5 THEN 3
    WHEN creatinine > 2.0 THEN 2
    WHEN creatinine > 1.2 THEN 1

    -- 数据不足且肌酐正常
    WHEN data_completeness = 'Insufficient' THEN 0

    ELSE 0
END AS kidney_score

-- 添加数据完整性标记
CASE
    WHEN cnt_24h >= 20 THEN 'Complete_24h'
    WHEN cnt_12h >= 8 THEN 'Complete_12h'
    WHEN cnt_6h >= 4 THEN 'Complete_6h'
    WHEN cnt_6h >= 1 THEN 'Limited_1h_plus'
    ELSE 'No_urine_data'
END AS urine_data_completeness
*/

-- 患者39553978的具体改进分析：
/*
当前情况：
- ICU住院：33小时
- 尿量数据：1小时（175ml）
- 体重：39.4kg
- 当前SOFA-2肾脏评分：0分
- 当前SOFA-1肾脏评分：4分（基于<200ml/24h标准）

改进后评估：
- 1小时尿量：175ml = 4.44 ml/kg/h
- 6小时等效评估：如果持续4.44 ml/kg/h，6小时约为26.6 ml/kg
- 12小时等效评估：如果持续4.44 ml/kg/h，12小时约为53.3 ml/kg
- 24小时等效评估：如果持续4.44 ml/kg/h，24小时约为106.6 ml/kg = 4.44 ml/kg/h

根据改进逻辑：
- 1小时数据不足以进行24小时标准评估
- 但4.44 ml/kg/h远高于0.3 ml/kg/h的阈值
- 因此仍评为0分是合理的

关键差异分析：
- SOFA-1使用绝对值：<200ml/24h = 4分
- SOFA-2使用体重标准化：<0.3 ml/kg/h × 39.4kg × 24h = 283 ml/24h
- 患者175ml/1小时如果外推到24小时：175ml × 24 = 4200ml（不现实）
- 更现实的是：患者只记录了1次尿量，可能总尿量就是175ml

结论：当前SOFA-2评为0分可能是合理的，但需要更好的数据完整性标记
*/

-- 实施建议：
/*
1. 修改step3.sql中的肾脏评分逻辑，采用分层评估策略
2. 添加数据完整性字段到最终输出表
3. 在统计分析中考虑数据完整性的影响
4. 对数据不足的患者进行敏感性分析
5. 在临床应用中提供数据完整性警告
*/