-- =================================================================
-- SOFA vs SOFA2 肾脏评分对比分析
-- =================================================================

-- 1. 传统SOFA肾脏评分分布
SELECT
    'Traditional SOFA' as scoring_system,
    renal as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM mimiciv_derived.first_day_sofa
WHERE renal IS NOT NULL
GROUP BY renal
ORDER BY renal;

-- 2. SOFA2肾脏评分分布
SELECT
    'SOFA2' as scoring_system,
    kidney as kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM mimiciv_derived.first_day_sofa2
WHERE kidney IS NOT NULL
GROUP BY kidney
ORDER BY kidney;

-- 3. 对比相同患者的肾脏评分差异
WITH sofa_comparison AS (
    SELECT
        fs.stay_id,
        fs.renal as sofa_renal,
        fs2.kidney as sofa2_renal,
        fs.renal - COALESCE(fs2.kidney, 0) as score_difference
    FROM mimiciv_derived.first_day_sofa fs
    LEFT JOIN mimiciv_derived.first_day_sofa2 fs2 ON fs.stay_id = fs2.stay_id
    WHERE fs.renal IS NOT NULL
)
SELECT
    score_difference,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM sofa_comparison
GROUP BY score_difference
ORDER BY score_difference;

-- 4. 查看具体的评分逻辑案例（前10个有差异的患者）
WITH sofa_comparison AS (
    SELECT
        fs.stay_id,
        fs.renal as sofa_renal,
        fs2.kidney as sofa2_renal,
        fs.renal - COALESCE(fs2.kidney, 0) as score_difference
    FROM mimiciv_derived.first_day_sofa fs
    LEFT JOIN mimiciv_derived.first_day_sofa2 fs2 ON fs.stay_id = fs2.stay_id
    WHERE fs.renal IS NOT NULL
      AND fs.renal != COALESCE(fs2.kidney, 0)
    LIMIT 10
)
SELECT * FROM sofa_comparison;