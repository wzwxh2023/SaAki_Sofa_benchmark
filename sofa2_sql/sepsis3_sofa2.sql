-- ------------------------------------------------------------------
-- Title: Sepsis-3 Identification Using SOFA-2
-- Description: Identifies sepsis-3 onset in ICU using SOFA-2 criteria
--
-- Sepsis-3 Definition:
-- - Suspected infection (antibiotic + culture within 72h/24h window)
-- - SOFA-2 score ≥ 2
--
-- This query identifies the EARLIEST time at which a patient meets
-- both criteria during their ICU stay.
--
-- Reference:
-- 1. Singer M, et al. The Third International Consensus Definitions
--    for Sepsis and Septic Shock (Sepsis-3). JAMA. 2016;315(8):801-810.
-- 2. Ranzani OT, et al. SOFA-2 Score. JAMA. 2025.
--
-- Difference from original sepsis3.sql:
-- - Uses SOFA-2 scores instead of SOFA-1
-- - May identify more patients due to updated cardiovascular scoring
-- - May have different timing due to new thresholds
-- ------------------------------------------------------------------

-- Extract rows with SOFA-2 >= 2
-- (implicitly assumes baseline SOFA-2 = 0 before ICU admission)
WITH sofa2 AS (
    SELECT stay_id
        , starttime, endtime
        , brain_24hours AS brain
        , respiratory_24hours AS respiratory
        , cardiovascular_24hours AS cardiovascular
        , liver_24hours AS liver
        , kidney_24hours AS kidney
        , hemostasis_24hours AS hemostasis
        , sofa2_24hours AS sofa_score
    FROM mimiciv_derived.sofa2  -- This would be the table created by sofa2.sql
    WHERE sofa2_24hours >= 2
)

, s1 AS (
    SELECT
        soi.subject_id
        , soi.stay_id
        -- Suspicion of infection columns
        , soi.ab_id
        , soi.antibiotic
        , soi.antibiotic_time
        , soi.culture_time
        , soi.suspected_infection
        , soi.suspected_infection_time
        , soi.specimen
        , soi.positive_culture
        -- SOFA-2 columns
        , starttime, endtime
        , brain, respiratory, cardiovascular, liver, kidney, hemostasis
        , sofa_score
        -- Sepsis-3 definition:
        -- SOFA-2 >= 2 AND suspected infection
        , sofa_score >= 2 AND suspected_infection = 1 AS sepsis3_sofa2
        -- Subselect to earliest suspicion/antibiotic/SOFA-2 row
        , ROW_NUMBER() OVER
        (
            PARTITION BY soi.stay_id
            ORDER BY
                suspected_infection_time, antibiotic_time, culture_time, endtime
        ) AS rn_sus
    FROM mimiciv_derived.suspicion_of_infection AS soi
    INNER JOIN sofa2
        ON soi.stay_id = sofa2.stay_id
            -- SOFA-2 must occur within -48h to +24h of suspected infection time
            AND sofa2.endtime >= soi.suspected_infection_time - INTERVAL '48 HOUR'
            AND sofa2.endtime <= soi.suspected_infection_time + INTERVAL '24 HOUR'
    -- Only include in-ICU rows
    WHERE soi.stay_id IS NOT NULL
)

SELECT
    subject_id, stay_id
    -- Infection-related columns
    , antibiotic_time
    , culture_time
    , suspected_infection_time
    -- SOFA-2 time (endtime is the latest time SOFA-2 score is valid)
    , endtime AS sofa2_time
    , sofa_score AS sofa2_score
    -- SOFA-2 component scores
    , brain, respiratory, cardiovascular, liver, kidney, hemostasis
    -- Sepsis-3 flag (based on SOFA-2)
    , sepsis3_sofa2 AS sepsis3
FROM s1
WHERE rn_sus = 1;
