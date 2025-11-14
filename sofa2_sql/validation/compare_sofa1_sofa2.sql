-- ------------------------------------------------------------------
-- Title: SOFA-1 vs SOFA-2 Comparison and Validation
-- Description: Side-by-side comparison of SOFA-1 and SOFA-2 scores
--
-- Purpose:
-- 1. Validate SOFA-2 implementation
-- 2. Analyze distribution differences
-- 3. Identify patients with score changes
-- 4. Generate statistics for manuscript
--
-- Expected findings (based on JAMA 2025 paper):
-- - Cardiovascular 2-point: SOFA-2 ~8.9% vs SOFA-1 ~0.9%
-- - Median total score: Similar for both versions
-- - AUROC for mortality: SOFA-2 ~0.79-0.81
-- ------------------------------------------------------------------

-- Compare first-day scores for all ICU patients
WITH comparison AS (
    SELECT
        ie.subject_id,
        ie.hadm_id,
        ie.stay_id,
        -- Patient demographics
        p.anchor_age AS age,
        p.gender,
        -- Outcomes
        a.hospital_expire_flag AS hospital_mortality,
        ie.los AS icu_los,
        -- SOFA-1 scores
        s1.sofa AS sofa1_total,
        s1.respiration AS sofa1_respiratory,
        s1.coagulation AS sofa1_coagulation,
        s1.liver AS sofa1_liver,
        s1.cardiovascular AS sofa1_cardiovascular,
        s1.cns AS sofa1_cns,
        s1.renal AS sofa1_renal,
        -- SOFA-2 scores
        s2.sofa2_total,
        s2.respiratory_24hours AS sofa2_respiratory,
        s2.hemostasis_24hours AS sofa2_hemostasis,
        s2.liver_24hours AS sofa2_liver,
        s2.cardiovascular_24hours AS sofa2_cardiovascular,
        s2.brain_24hours AS sofa2_brain,
        s2.kidney_24hours AS sofa2_kidney,
        -- Score differences
        s2.sofa2_total - s1.sofa AS sofa_total_diff,
        s2.cardiovascular_24hours - s1.cardiovascular AS cv_diff,
        s2.kidney_24hours - s1.renal AS kidney_diff,
        s2.respiratory_24hours - s1.respiration AS resp_diff
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.patients p
        ON ie.subject_id = p.subject_id
    INNER JOIN mimiciv_hosp.admissions a
        ON ie.hadm_id = a.hadm_id
    LEFT JOIN mimiciv_derived.first_day_sofa s1
        ON ie.stay_id = s1.stay_id
    LEFT JOIN mimiciv_derived.first_day_sofa2 s2  -- Assume this is created from first_day_sofa2.sql
        ON ie.stay_id = s2.stay_id
    WHERE s1.sofa IS NOT NULL OR s2.sofa2_total IS NOT NULL
)

-- =================================================================
-- SECTION 1: OVERALL DISTRIBUTION STATISTICS
-- =================================================================
SELECT
    '1. Overall Score Distribution' AS section,
    '------------------------------------' AS divider;

SELECT
    'SOFA-1 Total' AS score_type,
    COUNT(*) AS n_patients,
    ROUND(AVG(sofa1_total), 2) AS mean,
    ROUND(STDDEV(sofa1_total), 2) AS std,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa1_total) AS median,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sofa1_total) AS q1,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sofa1_total) AS q3,
    MIN(sofa1_total) AS min_score,
    MAX(sofa1_total) AS max_score
FROM comparison
UNION ALL
SELECT
    'SOFA-2 Total' AS score_type,
    COUNT(*) AS n_patients,
    ROUND(AVG(sofa2_total), 2) AS mean,
    ROUND(STDDEV(sofa2_total), 2) AS std,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_total) AS median,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sofa2_total) AS q1,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sofa2_total) AS q3,
    MIN(sofa2_total) AS min_score,
    MAX(sofa2_total) AS max_score
FROM comparison;

-- =================================================================
-- SECTION 2: COMPONENT SCORE DISTRIBUTIONS
-- =================================================================
SELECT
    '2. Component Score Distributions' AS section,
    '------------------------------------' AS divider;

-- Cardiovascular (KEY METRIC - should show improvement in 2-point distribution)
SELECT
    'Cardiovascular' AS component,
    score_value,
    COUNT(*) FILTER (WHERE sofa1_cardiovascular = score_value) AS sofa1_n,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa1_cardiovascular = score_value) / NULLIF(SUM(COUNT(*)) FILTER (WHERE sofa1_cardiovascular IS NOT NULL) OVER (), 0), 2) AS sofa1_pct,
    COUNT(*) FILTER (WHERE sofa2_cardiovascular = score_value) AS sofa2_n,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa2_cardiovascular = score_value) / NULLIF(SUM(COUNT(*)) FILTER (WHERE sofa2_cardiovascular IS NOT NULL) OVER (), 0), 2) AS sofa2_pct
FROM comparison
CROSS JOIN (SELECT generate_series(0, 4) AS score_value) scores
GROUP BY score_value
ORDER BY score_value;

-- Kidney/Renal
SELECT
    'Kidney/Renal' AS component,
    score_value,
    COUNT(*) FILTER (WHERE sofa1_renal = score_value) AS sofa1_n,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa1_renal = score_value) / NULLIF(SUM(COUNT(*)) FILTER (WHERE sofa1_renal IS NOT NULL) OVER (), 0), 2) AS sofa1_pct,
    COUNT(*) FILTER (WHERE sofa2_kidney = score_value) AS sofa2_n,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa2_kidney = score_value) / NULLIF(SUM(COUNT(*) FILTER (WHERE sofa2_kidney IS NOT NULL) OVER (), 0), 2) AS sofa2_pct
FROM comparison
CROSS JOIN (SELECT generate_series(0, 4) AS score_value) scores
GROUP BY score_value
ORDER BY score_value;

-- Respiratory
SELECT
    'Respiratory' AS component,
    score_value,
    COUNT(*) FILTER (WHERE sofa1_respiratory = score_value) AS sofa1_n,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa1_respiratory = score_value) / NULLIF(SUM(COUNT(*)) FILTER (WHERE sofa1_respiratory IS NOT NULL) OVER (), 0), 2) AS sofa1_pct,
    COUNT(*) FILTER (WHERE sofa2_respiratory = score_value) AS sofa2_n,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa2_respiratory = score_value) / NULLIF(SUM(COUNT(*)) FILTER (WHERE sofa2_respiratory IS NOT NULL) OVER (), 0), 2) AS sofa2_pct
FROM comparison
CROSS JOIN (SELECT generate_series(0, 4) AS score_value) scores
GROUP BY score_value
ORDER BY score_value;

-- =================================================================
-- SECTION 3: KEY VALIDATION METRICS
-- =================================================================
SELECT
    '3. Key Validation Metrics' AS section,
    '------------------------------------' AS divider;

-- Cardiovascular 2-point prevalence (CRITICAL VALIDATION)
SELECT
    'CV 2-point prevalence' AS metric,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa1_cardiovascular = 2) / NULLIF(COUNT(*), 0), 2) AS sofa1_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa2_cardiovascular = 2) / NULLIF(COUNT(*), 0), 2) AS sofa2_pct,
    'Expected SOFA-2: ~8.9%' AS expected_sofa2
FROM comparison
UNION ALL
-- Patients with SOFA >= 2 (sepsis threshold)
SELECT
    'Patients with score >= 2' AS metric,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa1_total >= 2) / NULLIF(COUNT(*), 0), 2) AS sofa1_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa2_total >= 2) / NULLIF(COUNT(*), 0), 2) AS sofa2_pct,
    'For Sepsis-3 identification' AS expected_sofa2
FROM comparison;

-- =================================================================
-- SECTION 4: PATIENTS WITH SCORE CHANGES
-- =================================================================
SELECT
    '4. Patients with Score Changes' AS section,
    '------------------------------------' AS divider;

SELECT
    CASE
        WHEN sofa_total_diff > 0 THEN 'SOFA-2 higher'
        WHEN sofa_total_diff < 0 THEN 'SOFA-1 higher'
        ELSE 'Same score'
    END AS score_change,
    COUNT(*) AS n_patients,
    ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS percentage,
    ROUND(AVG(ABS(sofa_total_diff)), 2) AS avg_difference
FROM comparison
WHERE sofa1_total IS NOT NULL AND sofa2_total IS NOT NULL
GROUP BY
    CASE
        WHEN sofa_total_diff > 0 THEN 'SOFA-2 higher'
        WHEN sofa_total_diff < 0 THEN 'SOFA-1 higher'
        ELSE 'Same score'
    END
ORDER BY n_patients DESC;

-- =================================================================
-- SECTION 5: CORRELATION WITH MORTALITY
-- =================================================================
SELECT
    '5. Mortality Prediction' AS section,
    '------------------------------------' AS divider;

-- Mortality by SOFA score categories
SELECT
    score_category,
    COUNT(*) AS n_patients,
    ROUND(100.0 * COUNT(*) FILTER (WHERE hospital_mortality = 1) / NULLIF(COUNT(*), 0), 2) AS sofa1_mortality_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE hospital_mortality = 1) / NULLIF(COUNT(*), 0), 2) AS sofa2_mortality_pct
FROM (
    SELECT
        hospital_mortality,
        CASE
            WHEN sofa1_total < 2 THEN '0-1 (low)'
            WHEN sofa1_total >= 2 AND sofa1_total < 6 THEN '2-5 (moderate)'
            WHEN sofa1_total >= 6 AND sofa1_total < 12 THEN '6-11 (high)'
            ELSE '12+ (very high)'
        END AS score_category
    FROM comparison
    WHERE sofa1_total IS NOT NULL
) sub
GROUP BY score_category
ORDER BY
    CASE score_category
        WHEN '0-1 (low)' THEN 1
        WHEN '2-5 (moderate)' THEN 2
        WHEN '6-11 (high)' THEN 3
        ELSE 4
    END;

-- =================================================================
-- SECTION 6: LARGEST SCORE DIFFERENCES
-- =================================================================
SELECT
    '6. Patients with Largest Differences' AS section,
    '------------------------------------' AS divider;

SELECT
    stay_id,
    age,
    gender,
    sofa1_total,
    sofa2_total,
    sofa_total_diff,
    cv_diff AS cardiovascular_diff,
    kidney_diff,
    resp_diff AS respiratory_diff,
    hospital_mortality
FROM comparison
WHERE ABS(sofa_total_diff) >= 2
ORDER BY ABS(sofa_total_diff) DESC
LIMIT 20;

-- =================================================================
-- SECTION 7: SUMMARY FOR MANUSCRIPT
-- =================================================================
SELECT
    '7. Summary Statistics for Manuscript' AS section,
    '------------------------------------' AS divider;

SELECT
    'Total ICU stays analyzed' AS metric,
    COUNT(*) AS value,
    '' AS notes
FROM comparison
UNION ALL
SELECT
    'SOFA-1 median (IQR)' AS metric,
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa1_total) AS TEXT) AS value,
    '(' || PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sofa1_total) ||
    '-' || PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sofa1_total) || ')' AS notes
FROM comparison
UNION ALL
SELECT
    'SOFA-2 median (IQR)' AS metric,
    CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_total) AS TEXT) AS value,
    '(' || PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sofa2_total) ||
    '-' || PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sofa2_total) || ')' AS notes
FROM comparison
UNION ALL
SELECT
    'Hospital mortality' AS metric,
    CAST(COUNT(*) FILTER (WHERE hospital_mortality = 1) AS TEXT) AS value,
    '(' || ROUND(100.0 * COUNT(*) FILTER (WHERE hospital_mortality = 1) / NULLIF(COUNT(*), 0), 1) || '%)' AS notes
FROM comparison;
