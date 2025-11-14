-- ------------------------------------------------------------------
-- Title: Sepsis-3 Identification: SOFA-1 vs SOFA-2 Comparison
-- Description: Compare sepsis patients identified using SOFA-1 vs SOFA-2
--
-- Sepsis-3 Definition:
-- - SOFA score >= 2 (baseline assumed to be 0)
-- - Suspected infection (antibiotic + culture within time window)
--
-- This compares which patients are identified as septic by each version
-- ------------------------------------------------------------------

WITH sepsis1_patients AS (
    SELECT DISTINCT
        stay_id,
        subject_id,
        suspected_infection_time AS sepsis1_time,
        sofa_score AS sofa1_score,
        1 AS sepsis1_flag
    FROM mimiciv_derived.sepsis3
    WHERE sepsis3 = TRUE  -- Confirmed sepsis by SOFA-1
)

, sepsis2_patients AS (
    SELECT DISTINCT
        stay_id,
        subject_id,
        suspected_infection_time AS sepsis2_time,
        sofa2_score AS sofa2_score,
        1 AS sepsis2_flag
    FROM mimiciv_derived.sepsis3_sofa2
    WHERE sepsis3 = TRUE  -- Confirmed sepsis by SOFA-2
)

, all_icu_stays AS (
    SELECT DISTINCT
        ie.stay_id,
        ie.subject_id,
        ie.hadm_id,
        ie.intime,
        ie.outtime,
        -- Check if patient has suspected infection
        CASE WHEN soi.stay_id IS NOT NULL THEN 1 ELSE 0 END AS has_suspected_infection
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.suspicion_of_infection soi
        ON ie.stay_id = soi.stay_id
)

, sepsis_comparison AS (
    SELECT
        icu.stay_id,
        icu.subject_id,
        icu.hadm_id,
        icu.has_suspected_infection,

        -- Sepsis flags
        COALESCE(sp1.sepsis1_flag, 0) AS sepsis1,
        COALESCE(sp2.sepsis2_flag, 0) AS sepsis2,

        -- SOFA scores at sepsis time
        sp1.sofa1_score,
        sp2.sofa2_score,

        -- Sepsis timing
        sp1.sepsis1_time,
        sp2.sepsis2_time,

        -- Agreement categories
        CASE
            WHEN COALESCE(sp1.sepsis1_flag, 0) = 1 AND COALESCE(sp2.sepsis2_flag, 0) = 1
                THEN 'Both_Sepsis'
            WHEN COALESCE(sp1.sepsis1_flag, 0) = 0 AND COALESCE(sp2.sepsis2_flag, 0) = 0
                THEN 'Neither_Sepsis'
            WHEN COALESCE(sp1.sepsis1_flag, 0) = 1 AND COALESCE(sp2.sepsis2_flag, 0) = 0
                THEN 'SOFA1_Only'
            WHEN COALESCE(sp1.sepsis1_flag, 0) = 0 AND COALESCE(sp2.sepsis2_flag, 0) = 1
                THEN 'SOFA2_Only'
        END AS agreement_category

    FROM all_icu_stays icu
    LEFT JOIN sepsis1_patients sp1 ON icu.stay_id = sp1.stay_id
    LEFT JOIN sepsis2_patients sp2 ON icu.stay_id = sp2.stay_id
)

SELECT * FROM sepsis_comparison;
