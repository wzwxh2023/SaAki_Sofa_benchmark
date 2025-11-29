-- This query extracts data for comparing SOFA1 and SOFA2 scores for each patient's first ICU stay.
-- All table and column names have been verified by inspecting the database schema directly.

-- Step 1: Use a Common Table Expression (CTE) to identify the first stay for each patient.
WITH first_admission_stays AS (
    SELECT
        subject_id,
        stay_id,
        hadm_id,
        -- Use the ROW_NUMBER() window function to rank stays by time for each patient
        ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime ASC) as rn
    FROM
        mimiciv_icu.icustays
)
-- Step 2: Select from the CTE where rn=1 (the first stay) and join with other tables.
SELECT
    fas.subject_id,
    fas.stay_id,
    fas.hadm_id,
    adm.hospital_expire_flag,
    -- Columns from mimiciv_derived.first_day_sofa
    s1.sofa AS sofa1_score,
    s1.respiration AS sofa1_respiration,
    s1.coagulation AS sofa1_coagulation,
    s1.liver AS sofa1_liver,
    s1.cardiovascular AS sofa1_cardiovascular,
    s1.cns AS sofa1_cns,
    s1.renal AS sofa1_renal,
    -- VERIFIED Columns from mimiciv_derived.first_day_sofa2
    s2.sofa2 AS sofa2_score,
    s2.respiratory AS sofa2_respiratory,
    s2.hemostasis AS sofa2_coagulation,
    s2.liver AS sofa2_liver,
    s2.cardiovascular AS sofa2_cardiovascular,
    s2.brain AS sofa2_cns,
    s2.kidney AS sofa2_renal
FROM first_admission_stays fas
-- Join with the admissions table in the 'mimiciv_hosp' schema
LEFT JOIN mimiciv_hosp.admissions adm ON fas.hadm_id = adm.hadm_id
-- Join with the SOFA score tables in the 'mimiciv_derived' schema
LEFT JOIN mimiciv_derived.first_day_sofa s1 ON fas.stay_id = s1.stay_id
LEFT JOIN mimiciv_derived.first_day_sofa2 s2 ON fas.stay_id = s2.stay_id
-- Filter to only include the first stay for each patient
WHERE fas.rn = 1
ORDER BY fas.subject_id;
