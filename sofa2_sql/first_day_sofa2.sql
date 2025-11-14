-- ------------------------------------------------------------------
-- Title: First Day SOFA-2 Score
-- Description: SOFA-2 score calculated on the FIRST DAY of ICU stay
--
-- Based on JAMA 2025 publication:
-- Ranzani OT, Singer M, Salluh JIF, et al.
-- Development and Validation of the Sequential Organ Failure Assessment (SOFA)-2 Score.
-- JAMA. 2025. doi:10.1001/jama.2025.20516
--
-- Time window: First 24 hours after ICU admission (-6h to +24h to capture
-- values immediately before ICU admission)
--
-- Usage: This table is commonly used for:
-- 1. ICU admission severity assessment
-- 2. Risk stratification
-- 3. Sepsis-3 identification (when combined with infection)
-- ------------------------------------------------------------------

-- =================================================================
-- HELPER: Get patient weight
-- =================================================================
WITH patient_weight AS (
    SELECT
        stay_id,
        weight
    FROM mimiciv_derived.first_day_weight
    WHERE weight IS NOT NULL AND weight > 0
)

-- =================================================================
-- HELPER: Delirium medications (within first 24h)
-- =================================================================
, delirium_meds_first_day AS (
    SELECT DISTINCT
        ie.stay_id,
        1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr
        ON ie.hadm_id = pr.hadm_id
    WHERE (LOWER(pr.drug) LIKE '%haloperidol%'
           OR LOWER(pr.drug) LIKE '%quetiapine%'
           OR LOWER(pr.drug) LIKE '%olanzapine%'
           OR LOWER(pr.drug) LIKE '%risperidone%')
          -- Check if active during first day
          AND pr.starttime::date <= (ie.intime)::date + INTERVAL '1' DAY
          AND COALESCE(pr.stoptime::date, (ie.intime)::date + INTERVAL '2' DAY)
              >= (ie.intime)::date
)

-- =================================================================
-- HELPER: Advanced respiratory support (first 24h)
-- =================================================================
, advanced_resp_first_day AS (
    SELECT
        ie.stay_id,
        MAX(CASE
            WHEN v.ventilation_status IN ('InvasiveVent', 'Tracheostomy',
                                           'NonInvasiveVent', 'HFNC')
            THEN 1
            ELSE 0
        END) AS has_advanced_support
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.ventilation v
        ON ie.stay_id = v.stay_id
            AND v.starttime >= ie.intime - INTERVAL '6 HOUR'
            AND v.starttime <= ie.intime + INTERVAL '1 DAY'
    GROUP BY ie.stay_id
)

-- =================================================================
-- HELPER: Mechanical circulatory support (first 24h)
-- =================================================================
, mechanical_support_first_day AS (
    SELECT DISTINCT
        ie.stay_id,
        1 AS has_mechanical_support
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.chartevents ce
        ON ie.stay_id = ce.stay_id
    WHERE ce.itemid IN (228001, 229270, 229272, 228000, 224797, 224798)
          AND ce.charttime >= ie.intime - INTERVAL '6 HOUR'
          AND ce.charttime <= ie.intime + INTERVAL '1 DAY'
)

-- =================================================================
-- HELPER: RRT status (first 24h)
-- =================================================================
, rrt_first_day AS (
    SELECT DISTINCT
        ie.stay_id,
        1 AS on_rrt
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.rrt r
        ON ie.stay_id = r.stay_id
    WHERE r.dialysis_active = 1
          AND r.charttime >= ie.intime - INTERVAL '6 HOUR'
          AND r.charttime <= ie.intime + INTERVAL '1 DAY'
)

-- =================================================================
-- SECTION 1: BRAIN/NEUROLOGICAL
-- =================================================================
, gcs_first_day AS (
    SELECT
        ie.stay_id,
        MIN(gcs.gcs) AS gcs_min
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.gcs gcs
        ON ie.stay_id = gcs.stay_id
            AND gcs.charttime >= ie.intime - INTERVAL '6 HOUR'
            AND gcs.charttime <= ie.intime + INTERVAL '1 DAY'
    GROUP BY ie.stay_id
)

-- =================================================================
-- SECTION 2: RESPIRATORY
-- =================================================================
, pafi_first_day AS (
    SELECT ie.stay_id
        , bg.charttime
        , bg.pao2fio2ratio
        -- Check if on advanced support
        , CASE
            WHEN v.stay_id IS NOT NULL THEN 1
            ELSE 0
        END AS on_advanced_support
        -- Check if on ECMO
        , CASE
            WHEN ms.has_mechanical_support = 1 THEN 1
            ELSE 0
        END AS on_ecmo
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.bg bg
        ON ie.subject_id = bg.subject_id
            AND bg.charttime >= ie.intime - INTERVAL '6 HOUR'
            AND bg.charttime <= ie.intime + INTERVAL '1 DAY'
            AND bg.specimen = 'ART.'
    LEFT JOIN mimiciv_derived.ventilation v
        ON ie.stay_id = v.stay_id
            AND bg.charttime >= v.starttime
            AND bg.charttime <= v.endtime
            AND v.ventilation_status IN ('InvasiveVent', 'Tracheostomy',
                                          'NonInvasiveVent', 'HFNC')
    LEFT JOIN mechanical_support_first_day ms
        ON ie.stay_id = ms.stay_id
)

, pf_first_day AS (
    SELECT
        stay_id,
        MIN(CASE WHEN on_advanced_support = 0 THEN pao2fio2ratio END) AS pf_novent_min,
        MIN(CASE WHEN on_advanced_support = 1 THEN pao2fio2ratio END) AS pf_vent_min,
        MAX(on_advanced_support) AS has_advanced_support,
        MAX(on_ecmo) AS on_ecmo
    FROM pafi_first_day
    GROUP BY stay_id
)

-- =================================================================
-- SECTION 3: CARDIOVASCULAR
-- =================================================================
, vitals_first_day AS (
    SELECT
        ie.stay_id,
        MIN(v.mbp) AS mbp_min
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.vitalsign v
        ON ie.stay_id = v.stay_id
            AND v.charttime >= ie.intime - INTERVAL '6 HOUR'
            AND v.charttime <= ie.intime + INTERVAL '1 DAY'
    GROUP BY ie.stay_id
)

-- Extract vasopressors from derived tables (first 24h)
, vaso_stg AS (
    SELECT ie.stay_id, 'norepinephrine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.norepinephrine mv
        ON ie.stay_id = mv.stay_id
            AND mv.starttime >= ie.intime - INTERVAL '6 HOUR'
            AND mv.starttime <= ie.intime + INTERVAL '1 DAY'
    UNION ALL
    SELECT ie.stay_id, 'epinephrine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.epinephrine mv
        ON ie.stay_id = mv.stay_id
            AND mv.starttime >= ie.intime - INTERVAL '6 HOUR'
            AND mv.starttime <= ie.intime + INTERVAL '1 DAY'
    UNION ALL
    SELECT ie.stay_id, 'dobutamine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.dobutamine mv
        ON ie.stay_id = mv.stay_id
            AND mv.starttime >= ie.intime - INTERVAL '6 HOUR'
            AND mv.starttime <= ie.intime + INTERVAL '1 DAY'
    UNION ALL
    SELECT ie.stay_id, 'dopamine' AS treatment, vaso_rate AS rate
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.dopamine mv
        ON ie.stay_id = mv.stay_id
            AND mv.starttime >= ie.intime - INTERVAL '6 HOUR'
            AND mv.starttime <= ie.intime + INTERVAL '1 DAY'
)

, vaso_mv AS (
    SELECT
        ie.stay_id,
        wt.weight,
        -- Convert to mcg/kg/min
        MAX(CASE WHEN v.treatment = 'norepinephrine' THEN v.rate / COALESCE(wt.weight, 80) END) AS rate_norepinephrine,
        MAX(CASE WHEN v.treatment = 'epinephrine' THEN v.rate / COALESCE(wt.weight, 80) END) AS rate_epinephrine,
        MAX(CASE WHEN v.treatment = 'dopamine' THEN v.rate / COALESCE(wt.weight, 80) END) AS rate_dopamine,
        MAX(CASE WHEN v.treatment = 'dobutamine' THEN v.rate / COALESCE(wt.weight, 80) END) AS rate_dobutamine
    FROM mimiciv_icu.icustays ie
    LEFT JOIN patient_weight wt
        ON ie.stay_id = wt.stay_id
    LEFT JOIN vaso_stg v
        ON ie.stay_id = v.stay_id
    GROUP BY ie.stay_id, wt.weight
)

-- =================================================================
-- SECTION 4: LIVER
-- =================================================================
, liver_first_day AS (
    SELECT
        ie.stay_id,
        MAX(enz.bilirubin_total) AS bilirubin_max
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.enzyme enz
        ON ie.hadm_id = enz.hadm_id
            AND enz.charttime >= ie.intime - INTERVAL '6 HOUR'
            AND enz.charttime <= ie.intime + INTERVAL '1 DAY'
    GROUP BY ie.stay_id
)

-- =================================================================
-- SECTION 5: KIDNEY
-- =================================================================
, kidney_labs_first_day AS (
    SELECT
        ie.stay_id,
        MAX(chem.creatinine) AS creatinine_max,
        MAX(chem.potassium) AS potassium_max
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.chemistry chem
        ON ie.hadm_id = chem.hadm_id
            AND chem.charttime >= ie.intime - INTERVAL '6 HOUR'
            AND chem.charttime <= ie.intime + INTERVAL '1 DAY'
    GROUP BY ie.stay_id
)

, kidney_bg_first_day AS (
    SELECT
        ie.stay_id,
        MIN(bg.ph) AS ph_min,
        MIN(bg.bicarbonate) AS bicarbonate_min
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.bg bg
        ON ie.subject_id = bg.subject_id
            AND bg.specimen = 'ART.'
            AND bg.charttime >= ie.intime - INTERVAL '6 HOUR'
            AND bg.charttime <= ie.intime + INTERVAL '1 DAY'
    GROUP BY ie.stay_id
)

, uo_first_day AS (
    SELECT
        ie.stay_id,
        uo.urineoutput,
        -- Convert to ml/kg/h
        uo.urineoutput / COALESCE(wt.weight, 80) / 24 AS uo_ml_kg_h
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.first_day_urine_output uo
        ON ie.stay_id = uo.stay_id
    LEFT JOIN patient_weight wt
        ON ie.stay_id = wt.stay_id
)

-- =================================================================
-- SECTION 6: HEMOSTASIS
-- =================================================================
, hemostasis_first_day AS (
    SELECT
        ie.stay_id,
        MIN(cbc.platelet) AS platelet_min
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.complete_blood_count cbc
        ON ie.hadm_id = cbc.hadm_id
            AND cbc.charttime >= ie.intime - INTERVAL '6 HOUR'
            AND cbc.charttime <= ie.intime + INTERVAL '1 DAY'
    GROUP BY ie.stay_id
)

-- =================================================================
-- COMBINE ALL COMPONENTS
-- =================================================================
, scorecomp AS (
    SELECT ie.stay_id, ie.subject_id, ie.hadm_id
        -- Brain
        , gcs.gcs_min
        , dm.on_delirium_med
        -- Respiratory
        , pf.pf_novent_min
        , pf.pf_vent_min
        , pf.has_advanced_support
        , pf.on_ecmo
        -- Cardiovascular
        , v.mbp_min
        , vaso.rate_norepinephrine
        , vaso.rate_epinephrine
        , vaso.rate_dopamine
        , vaso.rate_dobutamine
        , ms.has_mechanical_support
        -- Liver
        , liver.bilirubin_max
        -- Kidney
        , kl.creatinine_max
        , kl.potassium_max
        , kb.ph_min
        , kb.bicarbonate_min
        , uo.uo_ml_kg_h
        , rrt.on_rrt
        -- Hemostasis
        , hemo.platelet_min
    FROM mimiciv_icu.icustays ie
    LEFT JOIN gcs_first_day gcs
        ON ie.stay_id = gcs.stay_id
    LEFT JOIN delirium_meds_first_day dm
        ON ie.stay_id = dm.stay_id
    LEFT JOIN pf_first_day pf
        ON ie.stay_id = pf.stay_id
    LEFT JOIN vitals_first_day v
        ON ie.stay_id = v.stay_id
    LEFT JOIN vaso_mv vaso
        ON ie.stay_id = vaso.stay_id
    LEFT JOIN mechanical_support_first_day ms
        ON ie.stay_id = ms.stay_id
    LEFT JOIN liver_first_day liver
        ON ie.stay_id = liver.stay_id
    LEFT JOIN kidney_labs_first_day kl
        ON ie.stay_id = kl.stay_id
    LEFT JOIN kidney_bg_first_day kb
        ON ie.stay_id = kb.stay_id
    LEFT JOIN uo_first_day uo
        ON ie.stay_id = uo.stay_id
    LEFT JOIN rrt_first_day rrt
        ON ie.stay_id = rrt.stay_id
    LEFT JOIN hemostasis_first_day hemo
        ON ie.stay_id = hemo.stay_id
)

-- =================================================================
-- CALCULATE SOFA-2 SCORES
-- =================================================================
, scorecalc AS (
    SELECT stay_id, subject_id, hadm_id
        -- BRAIN/NEUROLOGICAL
        , CASE
            WHEN gcs_min <= 5 THEN 4
            WHEN gcs_min >= 6 AND gcs_min <= 8 THEN 3
            WHEN gcs_min >= 9 AND gcs_min <= 12 THEN 2
            WHEN (gcs_min >= 13 AND gcs_min <= 14) OR on_delirium_med = 1 THEN 1
            WHEN gcs_min = 15 AND COALESCE(on_delirium_med, 0) = 0 THEN 0
            WHEN gcs_min IS NULL AND COALESCE(on_delirium_med, 0) = 0 THEN NULL
            ELSE 0
        END AS brain

        -- RESPIRATORY
        , CASE
            WHEN on_ecmo = 1 THEN 4
            WHEN pf_vent_min <= 75 AND has_advanced_support = 1 THEN 4
            WHEN pf_vent_min <= 150 AND has_advanced_support = 1 THEN 3
            WHEN pf_novent_min <= 225 THEN 2
            WHEN pf_vent_min <= 225 THEN 2
            WHEN pf_novent_min <= 300 THEN 1
            WHEN pf_vent_min <= 300 THEN 1
            WHEN COALESCE(pf_vent_min, pf_novent_min) IS NULL THEN NULL
            ELSE 0
        END AS respiratory

        -- CARDIOVASCULAR
        , CASE
            WHEN has_mechanical_support = 1 THEN 4
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.4 THEN 4
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4
                 AND (COALESCE(rate_dopamine, 0) > 0 OR COALESCE(rate_dobutamine, 0) > 0)
                THEN 4
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4
                THEN 3
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2
                 AND (COALESCE(rate_dopamine, 0) > 0 OR COALESCE(rate_dobutamine, 0) > 0)
                THEN 3
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2
                THEN 2
            WHEN COALESCE(rate_dopamine, 0) > 0 OR COALESCE(rate_dobutamine, 0) > 0 THEN 2
            WHEN mbp_min < 70 THEN 1
            WHEN COALESCE(mbp_min, rate_norepinephrine, rate_epinephrine,
                          rate_dopamine, rate_dobutamine) IS NULL THEN NULL
            ELSE 0
        END AS cardiovascular

        -- LIVER
        , CASE
            WHEN bilirubin_max > 12.0 THEN 4
            WHEN bilirubin_max > 6.0 AND bilirubin_max <= 12.0 THEN 3
            WHEN bilirubin_max > 3.0 AND bilirubin_max <= 6.0 THEN 2
            WHEN bilirubin_max > 1.2 AND bilirubin_max <= 3.0 THEN 1
            WHEN bilirubin_max IS NULL THEN NULL
            ELSE 0
        END AS liver

        -- KIDNEY
        , CASE
            WHEN on_rrt = 1 THEN 4
            WHEN creatinine_max > 1.2
                 AND (potassium_max >= 6.0 OR (ph_min <= 7.2 AND bicarbonate_min <= 12))
                THEN 4
            WHEN creatinine_max > 3.5 THEN 3
            WHEN uo_ml_kg_h < 0.3 THEN 3
            WHEN creatinine_max > 2.0 AND creatinine_max <= 3.5 THEN 2
            WHEN uo_ml_kg_h >= 0.3 AND uo_ml_kg_h < 0.5 THEN 2
            WHEN creatinine_max > 1.2 AND creatinine_max <= 2.0 THEN 1
            WHEN COALESCE(creatinine_max, uo_ml_kg_h) IS NULL THEN NULL
            ELSE 0
        END AS kidney

        -- HEMOSTASIS
        , CASE
            WHEN platelet_min <= 50 THEN 4
            WHEN platelet_min <= 80 THEN 3
            WHEN platelet_min <= 100 THEN 2
            WHEN platelet_min <= 150 THEN 1
            WHEN platelet_min IS NULL THEN NULL
            ELSE 0
        END AS hemostasis

    FROM scorecomp
)

SELECT
    subject_id, hadm_id, stay_id
    -- Total SOFA-2 score (impute 0 for missing)
    , COALESCE(brain, 0)
      + COALESCE(respiratory, 0)
      + COALESCE(cardiovascular, 0)
      + COALESCE(liver, 0)
      + COALESCE(kidney, 0)
      + COALESCE(hemostasis, 0)
      AS sofa2_total
    -- Individual components
    , COALESCE(brain, 0) AS brain_24hours
    , COALESCE(respiratory, 0) AS respiratory_24hours
    , COALESCE(cardiovascular, 0) AS cardiovascular_24hours
    , COALESCE(liver, 0) AS liver_24hours
    , COALESCE(kidney, 0) AS kidney_24hours
    , COALESCE(hemostasis, 0) AS hemostasis_24hours
FROM scorecalc;
