-- ------------------------------------------------------------------
-- Title: SOFA-1 vs SOFA-2 Comprehensive Comparison
-- Description: Compare SOFA-1 and SOFA-2 scores across all ICU patients
--
-- This creates a comparison table with both SOFA-1 and SOFA-2 scores
-- for the first 24 hours of ICU admission, enabling:
-- 1. Distribution analysis
-- 2. Correlation analysis
-- 3. Agreement/disagreement analysis
-- 4. Component-level comparisons
-- ------------------------------------------------------------------

WITH sofa1_scores AS (
    SELECT
        subject_id,
        hadm_id,
        stay_id,
        sofa AS sofa1_total,
        cns AS sofa1_brain,
        respiration AS sofa1_respiratory,
        cardiovascular AS sofa1_cardiovascular,
        liver AS sofa1_liver,
        renal AS sofa1_kidney,
        coagulation AS sofa1_hemostasis
    FROM mimiciv_derived.first_day_sofa
)

, sofa2_scores AS (
    SELECT
        subject_id,
        hadm_id,
        stay_id,
        sofa2_total AS sofa2_total,
        brain_24hours AS sofa2_brain,
        respiratory_24hours AS sofa2_respiratory,
        cardiovascular_24hours AS sofa2_cardiovascular,
        liver_24hours AS sofa2_liver,
        kidney_24hours AS sofa2_kidney,
        hemostasis_24hours AS sofa2_hemostasis
    FROM mimiciv_derived.first_day_sofa2
)

, combined_scores AS (
    SELECT
        COALESCE(s1.subject_id, s2.subject_id) AS subject_id,
        COALESCE(s1.hadm_id, s2.hadm_id) AS hadm_id,
        COALESCE(s1.stay_id, s2.stay_id) AS stay_id,

        -- SOFA-1 scores
        s1.sofa1_total,
        s1.sofa1_brain,
        s1.sofa1_respiratory,
        s1.sofa1_cardiovascular,
        s1.sofa1_liver,
        s1.sofa1_kidney,
        s1.sofa1_hemostasis,

        -- SOFA-2 scores
        s2.sofa2_total,
        s2.sofa2_brain,
        s2.sofa2_respiratory,
        s2.sofa2_cardiovascular,
        s2.sofa2_liver,
        s2.sofa2_kidney,
        s2.sofa2_hemostasis,

        -- Score differences (SOFA-2 - SOFA-1)
        s2.sofa2_total - s1.sofa1_total AS total_diff,
        s2.sofa2_brain - s1.sofa1_brain AS brain_diff,
        s2.sofa2_respiratory - s1.sofa1_respiratory AS respiratory_diff,
        s2.sofa2_cardiovascular - s1.sofa1_cardiovascular AS cardiovascular_diff,
        s2.sofa2_liver - s1.sofa1_liver AS liver_diff,
        s2.sofa2_kidney - s1.sofa1_kidney AS kidney_diff,
        s2.sofa2_hemostasis - s1.sofa1_hemostasis AS hemostasis_diff,

        -- Agreement flags
        (s1.sofa1_total >= 2) AS sofa1_high_risk,
        (s2.sofa2_total >= 2) AS sofa2_high_risk,
        (s1.sofa1_total >= 2 AND s2.sofa2_total >= 2) AS both_high_risk,
        (s1.sofa1_total < 2 AND s2.sofa2_total < 2) AS both_low_risk,
        (s1.sofa1_total >= 2 AND s2.sofa2_total < 2) AS sofa1_only_high,
        (s1.sofa1_total < 2 AND s2.sofa2_total >= 2) AS sofa2_only_high

    FROM sofa1_scores s1
    FULL OUTER JOIN sofa2_scores s2
        ON s1.stay_id = s2.stay_id
)

SELECT * FROM combined_scores;
