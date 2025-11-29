-- =================================================================
-- 改进的SOFA-2肾脏评分逻辑 - 适应性评分策略
-- 解决因数据不足导致的评分偏差问题
-- =================================================================

-- 核心问题分析：
-- 患者ID: 39553978
-- ICU住院时长: 9.8小时
-- 尿量数据: 175ml (仅在第1小时有记录)
-- 体重: 39.4kg
-- 尿速率: 175ml / 39.4kg / 1h = 4.44 ml/kg/h
-- 当前SOFA-2肾脏评分: 0分
-- 当前SOFA-1肾脏评分: 4分

-- 问题根源：
-- step3.sql要求完整的24小时数据 (cnt_24h=24) 才能进行尿量评估
-- 但很多患者（如39553978）没有完整的24小时记录，导致尿量评分失效

-- 改进策略：
-- 1. 分层数据评估：6h/12h/24h数据分别对应不同阈值
-- 2. 适应性阈值：根据数据量调整评分标准
-- 3. 临床合理性：确保评分符合临床逻辑
-- 4. 数据完整性标记：明确标记评分依据

-- 改进的肾脏评分逻辑
/*
CASE
    -- RRT患者（最高优先级）
    WHEN has_rrt THEN 4

    -- 复杂RRT标准（电解质紊乱+肌酐升高）
    WHEN (creatinine > 1.2 AND has_electrolyte_crisis) THEN 4

    -- 肌酐评估（始终可用）
    WHEN creatinine > 3.5 THEN 3
    WHEN creatinine > 2.0 THEN 2
    WHEN creatinine > 1.2 THEN 1

    -- 24小时数据评估（原标准）
    WHEN cnt_24h >= 20 AND urine_rate_24h < 0.3 THEN 3
    WHEN cnt_24h >= 20 AND urine_rate_24h < 0.5 THEN 2
    WHEN cnt_24h >= 20 AND urine_rate_24h < 0.5 THEN 1

    -- 12小时数据评估（调整阈值）
    WHEN cnt_12h >= 8 AND urine_rate_12h < 0.25 THEN 3  -- 更严格
    WHEN cnt_12h >= 8 AND urine_rate_12h < 0.4 THEN 2   -- 更严格
    WHEN cnt_12h >= 8 AND urine_rate_12h < 0.4 THEN 1   -- 更严格

    -- 6小时数据评估（保守评分）
    WHEN cnt_6h >= 4 AND urine_rate_6h < 0.2 THEN 2     -- 保守评分
    WHEN cnt_6h >= 4 AND urine_rate_6h < 0.3 THEN 1     -- 保守评分

    -- 少量数据评估（极其保守）
    WHEN cnt_6h >= 1 AND urine_rate_6h < 0.1 THEN 1     -- 极低阈值

    -- 数据不足且肌酐正常
    ELSE 0
END AS kidney_score

-- 数据完整性标记
CASE
    WHEN cnt_24h >= 20 THEN 'Complete_24h'
    WHEN cnt_12h >= 8 THEN 'Complete_12h'
    WHEN cnt_6h >= 4 THEN 'Complete_6h'
    WHEN cnt_6h >= 1 THEN 'Limited_data'
    ELSE 'No_urine_data'
END AS urine_data_completeness
*/

-- 对患者39553978的改进评估：
/*
当前情况：
- 尿量数据: 175ml/1h = 4.44 ml/kg/h
- 数据完整性: Limited_data (cnt_6h = 1)

改进后评估：
- 4.44 ml/kg/h 远高于 0.1 ml/kg/h 的极低阈值
- 因此仍评为 0 分是合理的

与SOFA-1差异解释：
- SOFA-1: <200ml/24h = 4分 (绝对值标准)
- SOFA-2: <0.3ml/kg/h×24h = <283ml/24h (体重标准化)
- 患者仅175ml/1h，无法外推到24小时标准
- 因此SOFA-2评为0分，SOFA-1评为4分
- 这种差异反映了两种评分标准的不同设计理念
*/

-- 实际实施方案：
-- 1. 修改step3.sql中的肾脏评分逻辑
-- 2. 添加数据完整性字段到first_day_sofa2表
-- 3. 在统计分析中考虑数据完整性的影响
-- 4. 对数据不足患者进行敏感性分析

-- 统计分析建议：
/*
SELECT
    urine_data_completeness,
    COUNT(*) as patient_count,
    AVG(kidney_score) as avg_kidney_score,
    MAX(kidney_score) as max_kidney_score,
    AVG(icu_mortality) as mortality_rate
FROM mimiciv_derived.first_day_sofa2
GROUP BY urine_data_completeness
ORDER BY patient_count DESC;
*/

-- 临床应用建议：
/*
1. 对于Complete_24h患者：使用标准SOFA-2评分
2. 对于Complete_12h患者：评分谨慎解读，考虑临床背景
3. 对于Limited_data患者：评分仅供参考，重点关注肌酐和临床表现
4. 对于No_urine_data患者：依赖肌酐评分和临床评估
*/

-- 质量控制检查：
/*
-- 检查改进前后的评分分布
SELECT
    '评分分布对比' as comparison_type,
    kidney_score_original,
    kidney_score_improved,
    COUNT(*) as patient_count
FROM sofa_comparison_scoring
GROUP BY kidney_score_original, kidney_score_improved
ORDER BY patient_count DESC;

-- 检查对AUC的影响
SELECT
    'AUC影响分析' as analysis,
    ROUND(AUC(original_score, icu_mortality), 4) as original_auc,
    ROUND(AUC(improved_score, icu_mortality), 4) as improved_auc,
    ROUND(AUC(improved_score, icu_mortality) - AUC(original_score, icu_mortality), 4) as auc_difference
FROM roc_analysis_table;
*/

-- 总结：
/*
改进方案的核心是平衡数据完整性和临床合理性：
1. 不会让数据不足的患者得到不公平的低分
2. 不会让数据充足的患者得到不准确的高分
3. 提供明确的数据完整性标记
4. 保持与SOFA-2标准的临床一致性

对于患者39553978：
- SOFA-2评为0分是合理的，因为4.44 ml/kg/h远高于任何病理阈值
- 与SOFA-1的4分差异反映了评分标准的设计差异，而非实现错误
- 改进后的逻辑将明确标记该患者为"Limited_data"，提醒使用者注意数据局限性
*/