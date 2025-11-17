-- =================================================================
-- SOFA-2 Scoring System - Optimized Version
-- Based on SOFA1 structure, implementing SOFA2 standards
-- =================================================================

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
),

-- =================================================================
-- Preprocessing Steps (Staging CTEs)
-- =================================================================

-- Step 1: Preprocess drug patterns (unified maintenance, avoid duplication)
, drug_params AS (
    SELECT
        -- Sedation/analgesia drugs (common ICU sedatives)
        ARRAY['%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
              '%fentanyl%', '%remifentanil%', '%morphine%', '%hydromorphone%',
              '%dexmedetomidine%', '%ketamine%', '%clonidine%', '%etomidate%'] AS sedation_patterns,
        -- Delirium drugs (antipsychotics for delirium control)
        ARRAY['%haloperidol%', '%haldol%', '%quetiapine%', '%seroquel%',
              '%olanzapine%', '%zyprexa%', '%risperidone%', '%risperdal%',
              '%ziprasidone%', '%geodon%', '%clozapine%', '%aripiprazole%'] AS delirium_patterns
),

-- Step 2: Preprocess all GCS measurements, including data cleaning and sedation status
, gcs_stg AS (
    SELECT
        gcs.stay_id,
        gcs.charttime,
        -- GCS data cleaning: handle abnormal values
        CASE
            WHEN gcs.gcs < 3 THEN 3
            WHEN gcs.gcs > 15 THEN 15
            ELSE gcs.gcs
        END AS gcs,
        -- Determine if sedation drugs are being infused at GCS measurement time
        MAX(CASE
            WHEN pr.starttime <= gcs.charttime
                 AND COALESCE(pr.stoptime, gcs.charttime + INTERVAL '1 minute') > gcs.charttime
                 AND LOWER(pr.drug) ILIKE ANY (SELECT sedation_patterns FROM drug_params)
            THEN 1 ELSE 0
        END) AS is_sedated
    FROM mimiciv_derived.gcs gcs
    -- Pre-join with icustays and prescriptions to avoid duplication in LATERAL
    INNER JOIN mimiciv_icu.icustays ie ON gcs.stay_id = ie.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE gcs.gcs IS NOT NULL
    GROUP BY gcs.stay_id, gcs.charttime, gcs.gcs
),

-- Step 3: Preprocess hourly delirium drug usage
, delirium_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN pr.starttime <= co.endtime
                 AND COALESCE(pr.stoptime, co.endtime) >= co.starttime
                 AND LOWER(pr.drug) ILIKE ANY (SELECT delirium_patterns FROM drug_params)
            THEN 1 ELSE 0
        END) AS on_delirium_med
    FROM co
    INNER JOIN mimiciv_icu.icustays ie ON co.stay_id = ie.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- BRAIN/Nervous System (Integrated version: performance optimized + clear logic)
-- =================================================================
, gcs AS (
    SELECT
        co.stay_id,
        co.hr,
        gcs_vals.gcs,
        -- GREATEST function: clearly express "take maximum" semantics + handle missing values
        GREATEST(
            -- Score source 1: GCS score (missing values default to 0 points)
            CASE
                WHEN gcs_vals.gcs IS NULL THEN 0
                WHEN gcs_vals.gcs <= 5  THEN 4
                WHEN gcs_vals.gcs <= 8  THEN 3  -- GCS 6-8
                WHEN gcs_vals.gcs <= 12 THEN 2  -- GCS 9-12
                WHEN gcs_vals.gcs <= 14 THEN 1  -- GCS 13-14
                ELSE 0  -- GCS 15
            END,
            -- Score source 2: Delirium drugs (SOFA2 standard: any delirium drug gets at least 1 point)
            CASE WHEN d.on_delirium_med = 1 THEN 1 ELSE 0 END
        ) AS brain
    FROM co
    -- Efficient LATERAL: find from preprocessed GCS table
    LEFT JOIN LATERAL (
        SELECT gcs.gcs, gcs.is_sedated
        FROM gcs_stg gcs
        WHERE gcs.stay_id = co.stay_id
          -- GCS measurement time must be before current hour end
          AND gcs.charttime <= co.endtime
        ORDER BY
          -- Priority 1: current hour, non-sedated GCS (SOFA2: last GCS before sedation)
          CASE WHEN gcs.charttime >= co.starttime AND gcs.is_sedated = 0 THEN 0 ELSE 1 END,
          -- Priority 2: any non-sedated GCS (core of backfill logic)
          gcs.is_sedated,
          -- Priority 3: most recent time (under first two conditions)
          gcs.charttime DESC
        LIMIT 1
    ) AS gcs_vals ON TRUE
    -- JOIN preprocessed delirium drug status to avoid repeated calculation
    LEFT JOIN delirium_hourly d ON co.stay_id = d.stay_id AND co.hr = d.hr
),

-- =================================================================
-- Respiratory System Pre-calculation CTEs (Performance optimization: pre-calculation-join-aggregation pattern)
-- =================================================================

-- Step 1: Pre-calculate all PF ratios (blood gas analysis)
, pf_ratios_all AS (
    SELECT
        ie.stay_id,
        bg.charttime,
        bg.pao2fio2ratio AS oxygen_ratio,
        CASE
            WHEN vd.stay_id IS NOT NULL THEN 1
            ELSE 0
        END AS has_advanced_support
    FROM mimiciv_derived.bg bg
    INNER JOIN mimiciv_icu.icustays ie ON ie.subject_id = bg.subject_id
    LEFT JOIN mimiciv_derived.ventilation vd
        ON ie.stay_id = vd.stay_id
        AND bg.charttime >= vd.starttime
        AND bg.charttime <= vd.endtime
        AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'Tracheostomy', 'HFNC')  -- SOFA2-defined advanced respiratory support
    WHERE bg.specimen = 'ART.'
      AND bg.pao2fio2ratio IS NOT NULL
      AND bg.pao2fio2ratio > 0
),

-- Step 2: Pre-calculate SpO2 and FiO2 raw data
, spo2_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        ce.valuenum AS spo2_value
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 220277  -- SpO2
      AND ce.valuenum > 0
      AND ce.valuenum < 98  -- SF ratio only valid when SpO2 < 98%
),

, fio2_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        ce.valuenum AS fio2_value  -- FiO2 percentage (21-100%)
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 223835  -- Correct FiO2 itemid
      AND ce.valuenum BETWEEN 21 AND 100  -- FiO2 percentage range
),

-- Step 3: Pre-calculate all SF ratios (SpO2:FiO2) - Fixed time matching version
, sf_ratios_all AS (
    SELECT
        spo2.stay_id,
        spo2.charttime,
        (spo2.spo2_value / (fio2.fio2_value / 100.0)) AS oxygen_ratio,  -- Key fix: convert percentage to decimal
        -- Respiratory support detection: strictly match same time point or nearest synchronized record
        CASE WHEN vd.stay_id IS NOT NULL THEN 1 ELSE 0 END AS has_advanced_support
    FROM spo2_raw spo2
    INNER JOIN fio2_raw fio2
        ON spo2.stay_id = fio2.stay_id
        -- Fix: strictly match same time point or nearest time point (within 5-minute window)
        AND ABS(EXTRACT(EPOCH FROM (fio2.charttime - spo2.charttime))) <= 300  -- 5-minute window
    -- Direct LEFT JOIN ventilation table, simplify complex LATERAL JOIN
    LEFT JOIN mimiciv_derived.ventilation vd
        ON spo2.stay_id = vd.stay_id
        AND spo2.charttime BETWEEN vd.starttime AND vd.endtime  -- Standard time-point-interval matching
        AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'Tracheostomy', 'HFNC')  -- SOFA2-defined advanced respiratory support
    WHERE spo2.spo2_value IS NOT NULL
      AND fio2.fio2_value IS NOT NULL
),

-- Step 4: Pre-calculate all ECMO records (consistent with circulatory system)
, ecmo_events AS (
    -- Method 1: ECMO equipment records (complete coverage, consistent with circulatory system)
    SELECT
        ce.stay_id,
        ce.charttime,
        1 AS ecmo_indicator
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (
        -- ECMO related itemid (based on actual data validation, fully consistent with circulatory system)
        224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
        229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
        228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
    )

    UNION ALL

    -- Method 2: ECMO procedures
    SELECT
        pe.stay_id,
        pe.starttime AS charttime,
        1 AS ecmo_indicator
    FROM mimiciv_icu.procedureevents pe
    WHERE pe.itemid IN (229529, 229530)  -- ECMO related procedures
),

-- =================================================================
-- Step 5: Hourly PF data aggregation (PF ratios only)
, pf_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(pf.oxygen_ratio) AS pf_ratio_min,
        MAX(pf.has_advanced_support) AS pf_has_support
    FROM co
    LEFT JOIN pf_ratios_all pf
        ON co.stay_id = pf.stay_id
        AND pf.charttime >= co.starttime
        AND pf.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- Step 6: Hourly SF data aggregation (SF ratios only)
, sf_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(sf.oxygen_ratio) AS sf_ratio_min,
        MAX(sf.has_advanced_support) AS sf_has_support
    FROM co
    LEFT JOIN sf_ratios_all sf
        ON co.stay_id = sf.stay_id
        AND sf.charttime >= co.starttime
        AND sf.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- Respiratory system hourly aggregation (strict PF priority at JOIN level)
-- =================================================================
, respiratory_hourly AS (
    SELECT
        co.stay_id,
        co.hr,

        -- ECMO status: whether ECMO is present within the hour
        COALESCE(MAX(ecmo.ecmo_indicator), 0) AS on_ecmo,

        -- Oxygenation index type: strict PF priority
        CASE
            WHEN pf.pf_ratio_min IS NOT NULL THEN 'PF'
            WHEN sf.sf_ratio_min IS NOT NULL THEN 'SF'
            ELSE NULL
        END AS ratio_type,

        -- Oxygenation index value: strictly corresponding PF or SF value
        COALESCE(pf.pf_ratio_min, sf.sf_ratio_min) AS oxygen_ratio,

        -- Respiratory support status: must match oxygenation index type!
        CASE
            WHEN pf.pf_ratio_min IS NOT NULL THEN pf.pf_has_support  -- Support status for PF
            WHEN sf.sf_ratio_min IS NOT NULL THEN sf.sf_has_support  -- Support status for SF
            ELSE 0
        END AS has_advanced_support

    FROM co
    -- First connect hourly PF data
    LEFT JOIN pf_hourly pf
        ON co.stay_id = pf.stay_id AND co.hr = pf.hr
    -- Only consider SF data when no PF data in the hour
    LEFT JOIN sf_hourly sf
        ON co.stay_id = sf.stay_id
        AND co.hr = sf.hr
        AND pf.pf_ratio_min IS NULL  -- Key: only connect SF when no PF
    -- Time window connection: ECMO events
    LEFT JOIN ecmo_events ecmo
        ON co.stay_id = ecmo.stay_id
        AND ecmo.charttime >= co.starttime
        AND ecmo.charttime < co.endtime
),

-- =================================================================
-- RESPIRATORY/Respiratory System (SOFA2 standard: final scoring calculation)
-- =================================================================
, respiratory AS (
    SELECT
        stay_id,
        hr,
        CASE
            -- 4 points: ECMO
            WHEN on_ecmo = 1 THEN 4
            -- 4 points: most severe hypoxemia + respiratory support
            WHEN oxygen_ratio <=
                CASE WHEN ratio_type = 'SF' THEN 120 ELSE 75 END
                AND has_advanced_support = 1 THEN 4
            -- 3 points: severe hypoxemia + respiratory support
            WHEN oxygen_ratio <=
                CASE WHEN ratio_type = 'SF' THEN 200 ELSE 150 END
                AND has_advanced_support = 1 THEN 3
            -- 2 points: moderate hypoxemia
            WHEN oxygen_ratio <=
                CASE WHEN ratio_type = 'SF' THEN 250 ELSE 225 END THEN 2
            -- 1 point: mild hypoxemia
            WHEN oxygen_ratio <= 300 THEN 1
            -- 0 points: normal or missing data
            WHEN oxygen_ratio > 300 OR oxygen_ratio IS NULL THEN 0
            ELSE 0
        END AS respiratory
    FROM respiratory_hourly
),

-- =================================================================
-- Preprocessing CTEs: Solve LATERAL JOIN performance issues
-- =================================================================

-- Step 1: Preprocess mechanical support (based on actual MIMIC-IV data)
, mechanical_support_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE WHEN ce.itemid IN (
            -- ECMO related itemid (based on actual data validation)
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
        ) THEN 1 ELSE 0 END) AS has_ecmo,
        MAX(CASE WHEN ce.itemid IN (
            -- IABP related itemid (based on actual data validation)
            224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986,
            225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355,
            225742
        ) THEN 1 ELSE 0 END) AS has_iabp,
        MAX(CASE WHEN ce.itemid IN (
            -- Impella related itemid (based on actual data validation, remove duplicate 227355)
            228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671,
            228171, 228172, 228167, 228170, 224314, 224318, 229898
        ) THEN 1 ELSE 0 END) AS has_impella,
        MAX(CASE WHEN ce.itemid IN (
            -- LVAD related itemid (based on actual data validation)
            229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 220128
        ) THEN 1 ELSE 0 END) AS has_lvad
    FROM co
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
        AND ce.charttime >= co.starttime
        AND ce.charttime < co.endtime
        AND ce.itemid IN (
            -- Complete mechanical support itemid list (deduplicated, total 63)
            -- ECMO (25)
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260,
            -- IABP (17)
            224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986,
            225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355,
            225742,
            -- Impella (16, remove duplicate 227355)
            228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897,
            229671, 228171, 228172, 228167, 228170, 224314, 224318, 229898,
            -- LVAD (9)
            220128
        )
    GROUP BY co.stay_id, co.hr
),

-- Step 2: Preprocess vital signs (MAP)
, vitalsign_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(vs.mbp) AS mbp_min
    FROM co
    LEFT JOIN mimiciv_derived.vitalsign vs
        ON co.stay_id = vs.stay_id
        AND vs.charttime >= co.starttime
        AND vs.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- Step 3: Preprocess vasoactive drugs
, vasoactive_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(va.norepinephrine) AS rate_norepinephrine,
        MAX(va.epinephrine) AS rate_epinephrine,
        MAX(va.dopamine) AS rate_dopamine,
        MAX(va.dobutamine) AS rate_dobutamine,
        MAX(va.vasopressin) AS rate_vasopressin,
        MAX(va.phenylephrine) AS rate_phenylephrine,
        MAX(va.milrinone) AS rate_milrinone
    FROM co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- CARDIOVASCULAR/Cardiovascular (SOFA2 standard: fixed dopamine grading logic)
-- =================================================================
, cardiovascular AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- 4 point conditions (by priority)
            -- 4a: Mechanical circulatory support (any device)
            WHEN COALESCE(mech.has_ecmo, 0) + COALESCE(mech.has_iabp, 0) +
                 COALESCE(mech.has_impella, 0) + COALESCE(mech.has_lvad, 0) > 0 THEN 4
            -- 4b: NE+Epi total base dose > 0.4 mcg/kg/min
            WHEN ne_epi_total_base_dose > 0.4 THEN 4
            -- 4c: NE+Epi > 0.2 and using other drugs
            WHEN ne_epi_total_base_dose > 0.2 AND any_other_agent_flag = 1 THEN 4
            -- 4d: Dopamine monotherapy > 40 μg/kg/min (SOFA2 special rule)
            WHEN dopamine_only > 40 THEN 4

            -- 3 point conditions (by priority)
            -- 3a: NE+Epi total base dose > 0.2 mcg/kg/min
            WHEN ne_epi_total_base_dose > 0.2 THEN 3
            -- 3b: NE+Epi > 0 and using other drugs
            WHEN ne_epi_total_base_dose > 0 AND any_other_agent_flag = 1 THEN 3
            -- 3c: Dopamine monotherapy >20 to ≤40 μg/kg/min (SOFA2 special rule)
            WHEN dopamine_only > 20 AND dopamine_only <= 40 THEN 3

            -- 2 point conditions (by priority)
            -- 2a: NE+Epi total base dose > 0
            WHEN ne_epi_total_base_dose > 0 THEN 2
            -- 2b: Using any other drugs
            WHEN any_other_agent_flag = 1 THEN 2
            -- 2c: Dopamine monotherapy ≤20 μg/kg/min (SOFA2 special rule)
            WHEN dopamine_only > 0 AND dopamine_only <= 20 THEN 2

            -- MAP grading conditions: only used when no vasoactive drugs (SOFA2 standard)
            -- 4 points: MAP < 40 mmHg and no vasoactive drugs
            WHEN vit.mbp_min < 40 AND ne_epi_total_base_dose = 0 AND any_other_agent_flag = 0
                 AND dopamine_only = 0 THEN 4
            -- 3 points: MAP 40-49 mmHg and no vasoactive drugs
            WHEN vit.mbp_min >= 40 AND vit.mbp_min < 50 AND ne_epi_total_base_dose = 0
                 AND any_other_agent_flag = 0 AND dopamine_only = 0 THEN 3
            -- 2 points: MAP 50-59 mmHg and no vasoactive drugs
            WHEN vit.mbp_min >= 50 AND vit.mbp_min < 60 AND ne_epi_total_base_dose = 0
                 AND any_other_agent_flag = 0 AND dopamine_only = 0 THEN 2
            -- 1 point: MAP 60-69 mmHg and no vasoactive drugs
            WHEN vit.mbp_min >= 60 AND vit.mbp_min < 70 AND ne_epi_total_base_dose = 0
                 AND any_other_agent_flag = 0 AND dopamine_only = 0 THEN 1

            -- 0 points: MAP >= 70 mmHg or normal situation
            ELSE 0
        END AS cardiovascular
    FROM co
    -- High-performance connection: direct JOIN pre-aggregated data, avoid LATERAL
    LEFT JOIN mechanical_support_hourly mech ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN vitalsign_hourly vit ON co.stay_id = vit.stay_id AND co.hr = vit.hr
    LEFT JOIN vasoactive_hourly vaso ON co.stay_id = vaso.stay_id AND co.hr = vaso.hr
    -- Calculate NE/Epi total base dose, dopamine monotherapy grading and other drug flags
    CROSS JOIN LATERAL (
        SELECT
            -- 1. Calculate NE/Epi total base dose
            (COALESCE(vaso.rate_norepinephrine, 0) / 2.0 + COALESCE(vaso.rate_epinephrine, 0)) AS ne_epi_total_base_dose,
            -- 2. Dopamine monotherapy dose (only when only dopamine is used)
            CASE WHEN COALESCE(vaso.rate_norepinephrine, 0) = 0
                  AND COALESCE(vaso.rate_epinephrine, 0) = 0
                  AND COALESCE(vaso.rate_dobutamine, 0) = 0
                  AND COALESCE(vaso.rate_vasopressin, 0) = 0
                  AND COALESCE(vaso.rate_phenylephrine, 0) = 0
                  AND COALESCE(vaso.rate_milrinone, 0) = 0
                 THEN COALESCE(vaso.rate_dopamine, 0)
                 ELSE 0
            END AS dopamine_only,
            -- 3. Other drug flags (exclude dopamine, as dopamine is handled separately)
            CASE WHEN COALESCE(vaso.rate_dobutamine, 0) > 0
                  OR COALESCE(vaso.rate_vasopressin, 0) > 0
                  OR COALESCE(vaso.rate_phenylephrine, 0) > 0
                  OR COALESCE(vaso.rate_milrinone, 0) > 0
                 THEN 1 ELSE 0
            END AS any_other_agent_flag
    ) dose_calc
),

-- Step 4: Preprocess bilirubin data (high-performance optimization)
, bilirubin_data AS (
    SELECT
        stay.stay_id,
        enz.charttime,
        enz.bilirubin_total
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.enzyme enz ON stay.hadm_id = enz.hadm_id
    WHERE enz.bilirubin_total IS NOT NULL
),

-- =================================================================
-- LIVER/Liver (SOFA2 standard: high-performance pre-aggregation version)
-- =================================================================
, liver AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MAX(bd.bilirubin_total) > 12.0 THEN 4
            WHEN MAX(bd.bilirubin_total) > 6.0 AND MAX(bd.bilirubin_total) <= 12.0 THEN 3
            WHEN MAX(bd.bilirubin_total) > 3.0 AND MAX(bd.bilirubin_total) <= 6.0 THEN 2
            WHEN MAX(bd.bilirubin_total) > 1.2 AND MAX(bd.bilirubin_total) <= 3.0 THEN 1
            WHEN MAX(bd.bilirubin_total) IS NULL THEN NULL
            ELSE 0
        END AS liver
    FROM co
    LEFT JOIN bilirubin_data bd
        ON co.stay_id = bd.stay_id
        AND bd.charttime >= co.starttime
        AND bd.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- Step 5: Preprocess kidney data (fixed logic error version)

-- Basic data preprocessing
, chemistry_data AS (
    SELECT
        stay.stay_id,
        chem.charttime,
        chem.creatinine
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.chemistry chem ON stay.hadm_id = chem.hadm_id
    WHERE chem.creatinine IS NOT NULL
),
bg_data AS (
    SELECT
        stay.stay_id,
        bg.charttime,
        bg.ph,
        bg.potassium,
        bg.bicarbonate
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.bg bg ON stay.subject_id = bg.subject_id
    WHERE bg.specimen = 'ART.'
),

-- Step 1: Calculate hourly urine output (ml/kg/hr) - fix hardcoded weight problem
urine_output_rate AS (
    SELECT
        uo.stay_id,
        icu.intime,
        uo.charttime,
        -- Use patient actual weight, default 70kg
        uo.urineoutput / COALESCE(wd.weight, 70) as urine_ml_per_kg
    FROM mimiciv_derived.urine_output uo
    LEFT JOIN mimiciv_derived.weight_durations wd
        ON uo.stay_id = wd.stay_id
        AND uo.charttime >= wd.starttime
        AND uo.charttime < wd.endtime
    LEFT JOIN mimiciv_icu.icustays icu ON uo.stay_id = icu.stay_id
),
urine_output_hourly_rate AS (
    SELECT
        stay_id,
        FLOOR(EXTRACT(EPOCH FROM (charttime - intime))/3600) AS hr,
        SUM(urine_ml_per_kg) as uo_ml_kg_hr
    FROM urine_output_rate
    GROUP BY stay_id, hr
),

-- Step 2: Use "Gaps and Islands" algorithm to calculate continuous low urine output time (fix cumulative vs continuous error)
urine_output_islands AS (
    SELECT
        stay_id,
        hr,
        -- Create continuous hour groups for each condition
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, is_low_05 ORDER BY hr) as island_low_05,
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, is_low_03 ORDER BY hr) as island_low_03,
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, is_anuric ORDER BY hr) as island_anuric,
        is_low_05, is_low_03, is_anuric
    FROM (
        SELECT
            stay_id, hr,
            -- Condition flags
            CASE WHEN uo_ml_kg_hr < 0.5 THEN 1 ELSE 0 END as is_low_05,
            CASE WHEN uo_ml_kg_hr < 0.3 THEN 1 ELSE 0 END as is_low_03,
            CASE WHEN uo_ml_kg_hr = 0 THEN 1 ELSE 0 END as is_anuric
        FROM urine_output_hourly_rate
    ) flagged
),
urine_output_durations AS (
    SELECT
        stay_id,
        hr,
        -- Calculate continuous duration for each condition
        CASE WHEN is_low_05 = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_low_05, island_low_05) ELSE 0 END as consecutive_low_05h,
        CASE WHEN is_low_03 = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_low_03, island_low_03) ELSE 0 END as consecutive_low_03h,
        CASE WHEN is_anuric = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_anuric, island_anuric) ELSE 0 END as consecutive_anuric_h
    FROM urine_output_islands
),

-- RRT status preprocessing
rrt_status AS (
    SELECT
        rrt.stay_id,
        FLOOR(EXTRACT(EPOCH FROM (rrt.charttime - stay.intime))/3600) AS hr,
        MAX(rrt.dialysis_active) as rrt_active
    FROM mimiciv_derived.rrt rrt
    JOIN mimiciv_icu.icustays stay ON rrt.stay_id = stay.stay_id
    GROUP BY rrt.stay_id, FLOOR(EXTRACT(EPOCH FROM (rrt.charttime - stay.intime))/3600)
),

-- =================================================================
-- KIDNEY/Kidney (SOFA2 standard: fixed nested aggregation syntax error)
-- =================================================================

-- Step 1: Pre-aggregate hourly kidney-related indicators
, kidney_hourly_aggregates AS (
    SELECT
        co.stay_id,
        co.hr,
        -- Creatinine indicators
        MAX(chem.creatinine) AS creatinine_max,
        -- Blood gas indicators
        MAX(bg.potassium) AS potassium_max,
        MIN(bg.ph) AS ph_min,
        MIN(bg.bicarbonate) AS bicarbonate_min,
        -- Urine output indicators
        MAX(uo.consecutive_low_05h) AS consecutive_low_05h_max,
        MAX(uo.consecutive_low_03h) AS consecutive_low_03h_max,
        MAX(uo.consecutive_anuric_h) AS consecutive_anuric_h_max,
        -- RRT status
        MAX(CASE WHEN rrt.rrt_active = 1 THEN 1 ELSE 0 END) AS rrt_active_flag
    FROM co
    LEFT JOIN chemistry_data chem
        ON co.stay_id = chem.stay_id
        AND chem.charttime >= co.starttime
        AND chem.charttime < co.endtime
    LEFT JOIN bg_data bg
        ON co.stay_id = bg.stay_id
        AND bg.charttime >= co.starttime
        AND bg.charttime < co.endtime
    LEFT JOIN rrt_status rrt ON co.stay_id = rrt.stay_id AND co.hr = rrt.hr
    LEFT JOIN urine_output_durations uo ON co.stay_id = uo.stay_id AND co.hr = uo.hr
    GROUP BY co.stay_id, co.hr
),

-- Step 2: Calculate final kidney score
, kidney AS (
    SELECT
        stay_id,
        hr,
        -- Use GREATEST function to get the highest score from all conditions
        GREATEST(
            -- RRT-based score
            CASE WHEN rrt_active_flag = 1 THEN 4 ELSE 0 END,

            -- RRT initiation criteria-based score
            CASE
                WHEN (creatinine_max > 1.2 OR consecutive_low_03h_max >= 6)
                     AND (COALESCE(potassium_max, 0) >= 6.0
                          OR (COALESCE(ph_min, 7.4) <= 7.2 AND COALESCE(bicarbonate_min, 24) <= 12))
                THEN 4 ELSE 0 END,

            -- Creatinine-based score
            CASE
                WHEN creatinine_max > 3.5 THEN 3
                WHEN creatinine_max > 2.0 THEN 2
                WHEN creatinine_max > 1.2 THEN 1
                ELSE 0 END,

            -- Urine output-based score (use continuous time not cumulative time)
            CASE
                WHEN consecutive_low_03h_max >= 24 THEN 3
                WHEN consecutive_anuric_h_max >= 12 THEN 3
                WHEN consecutive_low_05h_max >= 12 THEN 2
                WHEN consecutive_low_05h_max >= 6 AND consecutive_low_05h_max < 12 THEN 1
                ELSE 0 END
        ) AS kidney
    FROM kidney_hourly_aggregates
),

-- Step 6: Preprocess platelet data (high-performance optimization)
, platelet_data AS (
    SELECT
        stay.stay_id,
        cbc.charttime,
        cbc.platelet
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.complete_blood_count cbc ON stay.hadm_id = cbc.hadm_id
    WHERE cbc.platelet IS NOT NULL
),

-- =================================================================
-- HEMOSTASIS/Coagulation (SOFA2 standard: high-performance pre-aggregation version)
-- =================================================================
, hemostasis AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MIN(pd.platelet) <= 50 THEN 4
            WHEN MIN(pd.platelet) <= 80 THEN 3
            WHEN MIN(pd.platelet) <= 100 THEN 2
            WHEN MIN(pd.platelet) <= 150 THEN 1
            WHEN MIN(pd.platelet) IS NULL THEN NULL
            ELSE 0
        END AS hemostasis
    FROM co
    LEFT JOIN platelet_data pd
        ON co.stay_id = pd.stay_id
        AND pd.charttime >= co.starttime
        AND pd.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- Comprehensive Scoring (window function implementation referencing SOFA1)
-- =================================================================
, score_final AS (
    SELECT s.*
        -- 24-hour window worst values for each component
        , COALESCE(MAX(brain) OVER w, 0) AS brain_24hours
        , COALESCE(MAX(respiratory) OVER w, 0) AS respiratory_24hours
        , COALESCE(MAX(cardiovascular) OVER w, 0) AS cardiovascular_24hours
        , COALESCE(MAX(liver) OVER w, 0) AS liver_24hours
        , COALESCE(MAX(kidney) OVER w, 0) AS kidney_24hours
        , COALESCE(MAX(hemostasis) OVER w, 0) AS hemostasis_24hours
        -- SOFA2 total score
        , COALESCE(MAX(brain) OVER w, 0) + COALESCE(MAX(respiratory) OVER w, 0) +
         COALESCE(MAX(cardiovascular) OVER w, 0) + COALESCE(MAX(liver) OVER w, 0) +
         COALESCE(MAX(kidney) OVER w, 0) + COALESCE(MAX(hemostasis) OVER w, 0) AS sofa2_24hours
    FROM (
        SELECT co.stay_id, co.hadm_id, co.subject_id, co.hr, co.starttime, co.endtime,
               gcs.brain, respiratory.respiratory, cardiovascular.cardiovascular,
               liver.liver, kidney.kidney, hemostasis.hemostasis
        FROM co
        LEFT JOIN gcs ON co.stay_id = gcs.stay_id AND co.hr = gcs.hr
        LEFT JOIN respiratory ON co.stay_id = respiratory.stay_id AND co.hr = respiratory.hr
        LEFT JOIN cardiovascular ON co.stay_id = cardiovascular.stay_id AND co.hr = cardiovascular.hr
        LEFT JOIN liver ON co.stay_id = liver.stay_id AND co.hr = liver.hr
        LEFT JOIN kidney ON co.stay_id = kidney.stay_id AND co.hr = kidney.hr
        LEFT JOIN hemostasis ON co.stay_id = hemostasis.stay_id AND co.hr = hemostasis.hr
    ) s
    WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING)
)

-- =================================================================
-- Final Output
-- =================================================================
SELECT
    stay_id,
    hadm_id,
    subject_id,
    hr,
    starttime,
    endtime,
    -- SOFA2 standard: 24-hour window worst score
    brain_24hours AS brain,
    respiratory_24hours AS respiratory,
    cardiovascular_24hours AS cardiovascular,
    liver_24hours AS liver,
    kidney_24hours AS kidney,
    hemostasis_24hours AS hemostasis,
    sofa2_24hours AS sofa2_total
FROM score_final
WHERE hr >= 0
ORDER BY stay_id, hr;