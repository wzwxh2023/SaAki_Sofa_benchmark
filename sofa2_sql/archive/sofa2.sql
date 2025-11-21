-- ------------------------------------------------------------------
-- Title: Sequential Organ Failure Assessment (SOFA-2)
-- Description: SOFA-2 score calculation for **every hour** of ICU stay
--
-- This is the updated SOFA score based on JAMA 2025 publication:
-- Ranzani OT, Singer M, Salluh JIF, et al.
-- Development and Validation of the Sequential Organ Failure Assessment (SOFA)-2 Score.
-- JAMA. 2025. doi:10.1001/jama.2025.20516
--
-- Key updates from SOFA-1:
-- 1. Brain: Added delirium medication consideration
-- 2. Respiratory: New PF thresholds + advanced respiratory support
-- 3. Cardiovascular: Combined NE+Epi dosing + mechanical support
-- 4. Liver: Minor threshold adjustment (< to ≤)
-- 5. Kidney: Weight-based UO + RRT metabolic criteria
-- 6. Hemostasis: New platelet thresholds (≤80 for 3pts, ≤50 for 4pts)
--
-- Note: Compatible with MIMIC-IV PostgreSQL schema
-- For BigQuery, replace DATETIME_SUB with DATE_SUB and adjust syntax
-- ------------------------------------------------------------------

-- Use icustay_hourly to get a row for every hour in the ICU
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        -- start/endtime for this hour
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
)

-- =================================================================
-- HELPER CTE: Get patient weight (needed for weight-based UO only)
-- =================================================================
, patient_weight AS (
    SELECT
        stay_id,
        weight
    FROM mimiciv_derived.first_day_weight
    WHERE weight IS NOT NULL AND weight > 0
)

-- =================================================================
-- HELPER CTE: Delirium medications
-- =================================================================
, delirium_meds AS (
    SELECT DISTINCT
        ie.stay_id,
        pr.starttime::date AS startdate,
        pr.stoptime::date AS stopdate,
        1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr
        ON ie.hadm_id = pr.hadm_id
    WHERE (LOWER(pr.drug) LIKE '%haloperidol%' OR LOWER(pr.drug) LIKE '%haldol%'
           OR LOWER(pr.drug) LIKE '%quetiapine%' OR LOWER(pr.drug) LIKE '%seroquel%'
           OR LOWER(pr.drug) LIKE '%olanzapine%' OR LOWER(pr.drug) LIKE '%zyprexa%'
           OR LOWER(pr.drug) LIKE '%risperidone%' OR LOWER(pr.drug) LIKE '%risperdal%'
           OR LOWER(pr.drug) LIKE '%ziprasidone%' OR LOWER(pr.drug) LIKE '%geodon%')
           -- Note: Including both generic and brand names for comprehensive delirium medication detection
           -- Dexmedetomidine excluded as it's primarily a sedation agent, not a delirium treatment
)

-- =================================================================
-- HELPER CTE: Advanced respiratory support
-- =================================================================
, advanced_resp_support AS (
    -- Advanced support from ventilation table
    SELECT
        stay_id,
        starttime,
        endtime,
        ventilation_status,
        1 AS has_advanced_support
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')

    UNION ALL

    -- Add CPAP/BiPAP support from chartevents
    SELECT
        ce.stay_id,
        ce.charttime AS starttime,
        ce.charttime AS endtime,
        CASE
            WHEN ce.itemid IN (227583) THEN 'CPAP'  -- Autoset/CPAP
            WHEN ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582) THEN 'BiPAP'
            ELSE 'Other_NIV'
        END AS ventilation_status,
        1 AS has_advanced_support
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (227577, 227578, 227579, 227580, 227581, 227582, 227583)  -- All CPAP/BiPAP related items
      AND ce.valuenum IS NOT NULL
      AND (ce.valuenum > 0 OR ce.value IS NOT NULL)  -- Ensure there's an actual value
)

-- =================================================================
-- NOTE: CPAP/BiPAP detection has been integrated into advanced_resp_support CTE
-- above using correct MIMIC-IV itemids (227577-227583)
-- =================================================================

-- =================================================================
-- HELPER CTE: Mechanical circulatory support
-- (ECMO, IABP, LVAD, Impella)
-- =================================================================
, mechanical_support AS (
    SELECT DISTINCT
        stay_id,
        charttime,
        CASE
            WHEN itemid IN (228001, 229270, 229272) THEN 'ECMO'
            WHEN itemid IN (228000, 224797, 224798) THEN 'IABP'
            WHEN itemid IN (224828, 224829) THEN 'Impella'
            WHEN LOWER(ce.value) LIKE '%lvad%' THEN 'LVAD'
            WHEN LOWER(ce.value) LIKE '%ecmo%' THEN 'ECMO'
            WHEN LOWER(ce.value) LIKE '%iabp%' THEN 'IABP'
            WHEN LOWER(ce.value) LIKE '%impella%' THEN 'Impella'
        END AS device_type,
        1 AS has_mechanical_support
    FROM mimiciv_icu.chartevents ce
    WHERE itemid IN (228001, 229270, 229272, 228000, 224797, 224798, 224828, 224829)
       OR (itemid IN (
               SELECT itemid FROM mimiciv_icu.d_items
               WHERE LOWER(label) LIKE '%ecmo%'
                  OR LOWER(label) LIKE '%iabp%'
                  OR LOWER(label) LIKE '%impella%'
                  OR LOWER(label) LIKE '%lvad%'
           ) AND value IS NOT NULL)
)

-- =================================================================
-- HELPER CTE: RRT detection
-- =================================================================
, rrt_active AS (
    SELECT
        stay_id,
        charttime,
        dialysis_active AS on_rrt
    FROM mimiciv_derived.rrt
    WHERE dialysis_active = 1
)

-- =================================================================
-- HELPER CTE: RRT metabolic criteria
-- =================================================================
, rrt_metabolic_criteria AS (
    SELECT
        co.stay_id,
        co.hr,
        cr.creatinine_max,
        k.potassium_max,
        bg.ph_min,
        bg.bicarbonate_min,
        CASE
            WHEN cr.creatinine_max > 1.2
                 AND (k.potassium_max >= 6.0
                      OR (bg.ph_min <= 7.2 AND bg.bicarbonate_min <= 12))
            THEN 1
            ELSE 0
        END AS meets_rrt_criteria
    FROM co
    LEFT JOIN (
        SELECT ie.stay_id, chem.charttime, MAX(chem.creatinine) AS creatinine_max
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.chemistry chem
            ON ie.subject_id = chem.subject_id
            AND chem.charttime >= ie.intime
            AND chem.charttime < ie.outtime
        GROUP BY ie.stay_id, chem.charttime
    ) cr ON co.stay_id = cr.stay_id
        AND co.starttime < cr.charttime
        AND co.endtime >= cr.charttime
    LEFT JOIN (
        SELECT ie.stay_id, chem.charttime, MAX(chem.potassium) AS potassium_max
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.chemistry chem
            ON ie.subject_id = chem.subject_id
            AND chem.charttime >= ie.intime
            AND chem.charttime < ie.outtime
        GROUP BY ie.stay_id, chem.charttime
    ) k ON co.stay_id = k.stay_id
        AND co.starttime < k.charttime
        AND co.endtime >= k.charttime
    LEFT JOIN (
        SELECT ie.stay_id, bg.charttime, MIN(bg.ph) AS ph_min, MIN(bg.bicarbonate) AS bicarbonate_min
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.bg bg
            ON ie.subject_id = bg.subject_id
            AND bg.charttime >= ie.intime
            AND bg.charttime < ie.outtime
        WHERE bg.specimen = 'ART.'
        GROUP BY ie.stay_id, bg.charttime
    ) bg ON co.stay_id = bg.stay_id
        AND co.starttime < bg.charttime
        AND co.endtime >= bg.charttime
)

-- =================================================================
-- SECTION 1: BRAIN/NEUROLOGICAL
-- =================================================================
, gcs AS (
    SELECT co.stay_id, co.hr
        , MIN(gcs.gcs) AS gcs_min
    FROM co
    LEFT JOIN mimiciv_derived.gcs gcs
        ON co.stay_id = gcs.stay_id
            AND co.starttime < gcs.charttime
            AND co.endtime >= gcs.charttime
    GROUP BY co.stay_id, co.hr
)

, brain_delirium AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN dm.on_delirium_med = 1
                 AND (co.starttime)::date >= dm.startdate
                 AND (co.starttime)::date <= COALESCE(dm.stopdate, (co.starttime)::date + INTERVAL '1' DAY)
            THEN 1
            ELSE 0
        END) AS on_delirium_med
    FROM co
    LEFT JOIN delirium_meds dm
        ON co.stay_id = dm.stay_id
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 2: RESPIRATORY
-- =================================================================
, pafi AS (
    -- PaO2/FiO2 ratio with advanced respiratory support flag
    SELECT ie.stay_id
        , bg.charttime
        -- Check if on advanced respiratory support during this blood gas
        , CASE
            WHEN ars.stay_id IS NOT NULL THEN 1
            ELSE 0
        END AS on_advanced_support
        , bg.pao2fio2ratio
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_derived.bg bg
        ON ie.subject_id = bg.subject_id
        AND bg.specimen = 'ART.'
    LEFT JOIN advanced_resp_support ars
        ON ie.stay_id = ars.stay_id
            AND bg.charttime >= ars.starttime
            AND bg.charttime <= ars.endtime
)

-- =================================================================
-- SpO2:FiO2 ratio data (alternative when PaO2:FiO2 unavailable)
-- =================================================================
, spo2_data AS (
    -- Extract SpO2 data from chartevents
    SELECT
        ie.stay_id,
        ce.charttime,
        CASE
            WHEN ce.valuenum IS NOT NULL AND ce.valuenum > 0
            THEN CAST(ce.valuenum AS NUMERIC)
            ELSE NULL
        END AS spo2,
        ce.valueuom
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.chartevents ce
        ON ie.stay_id = ce.stay_id
    WHERE ce.itemid = 220227  -- "Arterial O2 Saturation"
      AND ce.valuenum IS NOT NULL
      AND ce.valuenum > 0
      AND ce.valuenum < 100  -- Physiologically valid range
)

, fio2_chart_data AS (
    -- Extract FiO2 data from chartevents for SF ratio
    SELECT
        ie.stay_id,
        ce.charttime,
        CASE
            WHEN ce.valueuom = '%' AND ce.valuenum IS NOT NULL
            THEN CAST(ce.valuenum AS NUMERIC) / 100
            WHEN ce.valuenum IS NOT NULL AND ce.valuenum <= 1
            THEN CAST(ce.valuenum AS NUMERIC)
            WHEN ce.valuenum IS NOT NULL AND ce.valuenum > 1
            THEN CAST(ce.valuenum AS NUMERIC) / 100
            ELSE NULL
        END AS fio2,
        ce.valueuom
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.chartevents ce
        ON ie.stay_id = ce.stay_id
    WHERE ce.itemid IN (229841, 229280, 230086)  -- FiO2 items from our data analysis
      AND ce.valuenum IS NOT NULL
      AND ce.valuenum > 0
      AND ce.valuenum <= 100  -- Valid FiO2 range
)

, sfi_data AS (
    -- Calculate SpO2:FiO2 ratios by hour
    SELECT
        co.stay_id,
        co.hr,
        -- Average SpO2 during the hour window
        AVG(spo2.spo2) AS spo2_avg,
        -- Average FiO2 during the hour window
        AVG(fio2.fio2) AS fio2_avg,
        -- SF ratio calculation (only when SpO2 < 98% per standard)
        CASE
            WHEN AVG(spo2.spo2) < 98 AND AVG(fio2.fio2) > 0 AND AVG(fio2.fio2) <= 1
            THEN AVG(spo2.spo2) / AVG(fio2.fio2)
            ELSE NULL
        END AS sfi_ratio,
        -- Advanced support flag during this hour
        MAX(ars.has_advanced_support) AS has_advanced_support
    FROM co
    LEFT JOIN spo2_data spo2
        ON co.stay_id = spo2.stay_id
        AND co.starttime <= spo2.charttime
        AND co.endtime >= spo2.charttime
    LEFT JOIN fio2_chart_data fio2
        ON co.stay_id = fio2.stay_id
        AND co.starttime <= fio2.charttime
        AND co.endtime >= fio2.charttime
    LEFT JOIN advanced_resp_support ars
        ON co.stay_id = ars.stay_id
        AND co.starttime <= ars.starttime
        AND co.endtime >= ars.endtime
    GROUP BY co.stay_id, co.hr
)

, respiratory_data AS (
    -- Comprehensive respiratory data combining PF and SF ratios
    SELECT
        co.stay_id,
        co.hr,
        -- PF ratio data (from blood gases)
        MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) AS pf_novent_min,
        MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) AS pf_vent_min,
        -- SF ratio data (from SpO2 and FiO2)
        MIN(sfi.sfi_ratio) AS sfi_ratio,
        MIN(sfi.spo2_avg) AS spo2_avg,
        -- Advanced support status (combine PF and SF data)
        COALESCE(MAX(pafi.on_advanced_support), MAX(sfi.has_advanced_support), 0) AS has_advanced_support,
        -- Determine which ratio type is available for scoring
        CASE
            WHEN MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END) IS NOT NULL
                 OR MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END) IS NOT NULL
            THEN 'PF'
            WHEN MIN(sfi.sfi_ratio) IS NOT NULL
            THEN 'SF'
            ELSE NULL
        END AS ratio_type,
        -- Get the appropriate oxygen ratio for scoring (PF takes priority over SF)
        COALESCE(
            MIN(CASE WHEN pafi.on_advanced_support = 1 THEN pafi.pao2fio2ratio END),
            MIN(CASE WHEN pafi.on_advanced_support = 0 THEN pafi.pao2fio2ratio END),
            MIN(sfi.sfi_ratio)
        ) AS oxygen_ratio
    FROM co
    LEFT JOIN pafi
        ON co.stay_id = pafi.stay_id
        AND co.starttime < pafi.charttime
        AND co.endtime >= pafi.charttime
    LEFT JOIN sfi_data sfi
        ON co.stay_id = sfi.stay_id AND co.hr = sfi.hr
    GROUP BY co.stay_id, co.hr
)

-- Check for ECMO (respiratory indication)
, ecmo_resp AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(ms.has_mechanical_support) AS on_ecmo
    FROM co
    LEFT JOIN mechanical_support ms
        ON co.stay_id = ms.stay_id
            AND ms.device_type = 'ECMO'
            AND co.starttime < ms.charttime
            AND co.endtime >= ms.charttime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 3: CARDIOVASCULAR
-- =================================================================
, vs AS (
    SELECT co.stay_id, co.hr
        , MIN(vs.mbp) AS mbp_min
    FROM co
    LEFT JOIN mimiciv_derived.vitalsign vs
        ON co.stay_id = vs.stay_id
            AND co.starttime < vs.charttime
            AND co.endtime >= vs.charttime
    GROUP BY co.stay_id, co.hr
)

-- Primary vasopressors (NE and Epi - require dose thresholds)
, vaso_primary AS (
    SELECT
        co.stay_id
        , co.hr
        -- Norepinephrine (mcg/kg/min) - already weight-based from derived table
        , MAX(nor.vaso_rate) AS rate_norepinephrine
        -- Epinephrine (mcg/kg/min) - already weight-based from derived table
        , MAX(epi.vaso_rate) AS rate_epinephrine
    FROM co
    LEFT JOIN mimiciv_derived.norepinephrine nor
        ON co.stay_id = nor.stay_id
            AND co.endtime > nor.starttime
            AND co.endtime <= nor.endtime
    LEFT JOIN mimiciv_derived.epinephrine epi
        ON co.stay_id = epi.stay_id
            AND co.endtime > epi.starttime
            AND co.endtime <= epi.endtime
    GROUP BY co.stay_id, co.hr
)

-- Secondary vasopressors (binary indicators - any dose counts)
, vaso_secondary AS (
    SELECT
        co.stay_id
        , co.hr
        -- Any dose of dopamine (binary: 0/1)
        , CASE WHEN MAX(dop.vaso_rate) > 0 THEN 1 ELSE 0 END AS on_dopamine
        -- Any dose of dobutamine (binary: 0/1)
        , CASE WHEN MAX(dob.vaso_rate) > 0 THEN 1 ELSE 0 END AS on_dobutamine
        -- Any dose of vasopressin (binary: 0/1)
        , CASE WHEN MAX(vas.rate) > 0 THEN 1 ELSE 0 END AS on_vasopressin
        -- Any dose of phenylephrine (binary: 0/1)
        , CASE WHEN MAX(phen.rate) > 0 THEN 1 ELSE 0 END AS on_phenylephrine
    FROM co
    LEFT JOIN mimiciv_derived.dopamine dop
        ON co.stay_id = dop.stay_id
            AND co.endtime > dop.starttime
            AND co.endtime <= dop.endtime
    LEFT JOIN mimiciv_derived.dobutamine dob
        ON co.stay_id = dob.stay_id
            AND co.endtime > dob.starttime
            AND co.endtime <= dob.endtime
    LEFT JOIN (
        SELECT stay_id, starttime, endtime, rate
        FROM mimiciv_icu.inputevents
        WHERE itemid = 222315  -- Vasopressin
          AND rate IS NOT NULL AND rate > 0
    ) vas ON co.stay_id = vas.stay_id
        AND co.endtime > vas.starttime
        AND co.endtime <= vas.endtime
    LEFT JOIN (
        SELECT stay_id, starttime, endtime, rate
        FROM mimiciv_icu.inputevents
        WHERE itemid = 221749  -- Phenylephrine
          AND rate IS NOT NULL AND rate > 0
    ) phen ON co.stay_id = phen.stay_id
        AND co.endtime > phen.starttime
        AND co.endtime <= phen.endtime
    GROUP BY co.stay_id, co.hr
)


, mech_support AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(ms.has_mechanical_support) AS has_mechanical_support
    FROM co
    LEFT JOIN mechanical_support ms
        ON co.stay_id = ms.stay_id
            AND co.starttime < ms.charttime
            AND co.endtime >= ms.charttime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 4: LIVER
-- =================================================================
, bili AS (
    SELECT co.stay_id, co.hr
        , MAX(enz.bilirubin_total) AS bilirubin_max
    FROM co
    LEFT JOIN mimiciv_derived.enzyme enz
        ON co.hadm_id = enz.hadm_id
            AND co.starttime < enz.charttime
            AND co.endtime >= enz.charttime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 5: KIDNEY
-- =================================================================
, cr AS (
    SELECT co.stay_id, co.hr
        , MAX(chem.creatinine) AS creatinine_max
        , MAX(chem.potassium) AS potassium_max
    FROM co
    LEFT JOIN mimiciv_derived.chemistry chem
        ON co.hadm_id = chem.hadm_id
            AND co.starttime < chem.charttime
            AND co.endtime >= chem.charttime
    GROUP BY co.stay_id, co.hr
)

, bg_metabolic AS (
    SELECT co.stay_id, co.hr
        , MIN(bg.ph) AS ph_min
        , MIN(bg.bicarbonate) AS bicarbonate_min
    FROM co
    LEFT JOIN mimiciv_derived.bg bg
        ON co.subject_id = bg.subject_id
            AND bg.specimen = 'ART.'
            AND co.starttime < bg.charttime
            AND co.endtime >= bg.charttime
    GROUP BY co.stay_id, co.hr
)


-- SOFA-2 Kidney scoring: Precise continuous urine output analysis
, uo_continuous AS (
    -- Step 1: Raw urine data with weight
    WITH uo_raw AS (
        SELECT
            u.stay_id,
            u.charttime,
            u.urineoutput,
            w.weight,
            LAG(u.charttime) OVER (PARTITION BY u.stay_id ORDER BY u.charttime) as last_charttime
        FROM mimiciv_derived.urine_output u
        LEFT JOIN patient_weight w ON u.stay_id = w.stay_id
    ),

    -- Step 2: Calculate intervals and rates
    uo_interval AS (
        SELECT
            stay_id,
            charttime,
            urineoutput,
            weight,
            CASE
                WHEN last_charttime IS NULL THEN NULL
                ELSE EXTRACT(EPOCH FROM (charttime - last_charttime)) / 3600.0
            END AS interval_hours
        FROM uo_raw
    ),

    -- Step 3: Calculate ml/kg/h rates
    uo_rate AS (
        SELECT
            stay_id,
            charttime,
            interval_hours,
            urineoutput,
            weight,
            CASE
                WHEN interval_hours IS NULL OR weight = 0 THEN NULL
                ELSE (urineoutput / weight) / interval_hours
            END AS uo_ml_kg_h
        FROM uo_interval
    ),

    -- Step 4: Flag low output and create groups
    uo_flags AS (
        SELECT
            stay_id,
            charttime,
            interval_hours,
            uo_ml_kg_h,
            CASE WHEN uo_ml_kg_h < 0.5 THEN 1 ELSE 0 END AS low_05_flag,
            CASE WHEN uo_ml_kg_h < 0.3 THEN 1 ELSE 0 END AS low_03_flag,
            CASE WHEN urineoutput = 0 THEN 1 ELSE 0 END AS anuria_flag,

            -- Create group IDs for continuous periods
            ROW_NUMBER() OVER (PARTITION BY stay_id ORDER BY charttime) -
            ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN uo_ml_kg_h < 0.5 THEN 1 ELSE 0 END ORDER BY charttime) AS grp_low_05,
            ROW_NUMBER() OVER (PARTITION BY stay_id ORDER BY charttime) -
            ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN uo_ml_kg_h < 0.3 THEN 1 ELSE 0 END ORDER BY charttime) AS grp_low_03,
            ROW_NUMBER() OVER (PARTITION BY stay_id ORDER BY charttime) -
            ROW_NUMBER() OVER (PARTITION BY stay_id, CASE WHEN urineoutput = 0 THEN 1 ELSE 0 END ORDER BY charttime) AS grp_anuria
        FROM uo_rate
    ),

    -- Step 5: Calculate cumulative durations
    uo_durations AS (
        SELECT
            stay_id,
            charttime,
            uo_ml_kg_h,

            -- Cumulative hours for each continuous low output period
            CASE
                WHEN low_05_flag = 1 THEN
                    SUM(interval_hours) OVER (PARTITION BY stay_id, grp_low_05)
                ELSE 0
            END AS hours_low_05,

            CASE
                WHEN low_03_flag = 1 THEN
                    SUM(interval_hours) OVER (PARTITION BY stay_id, grp_low_03)
                ELSE 0
            END AS hours_low_03,

            CASE
                WHEN anuria_flag = 1 THEN
                    SUM(interval_hours) OVER (PARTITION BY stay_id, grp_anuria)
                ELSE 0
            END AS hours_anuria
        FROM uo_flags
    )

    SELECT * FROM uo_durations
),

-- Step 6: Get maximum continuous durations for each hour
uo_max_durations AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(uc.hours_low_05) AS max_hours_low_05,
        MAX(uc.hours_low_03) AS max_hours_low_03,
        MAX(uc.hours_anuria) AS max_hours_anuria
    FROM co
    LEFT JOIN (
        SELECT stay_id, charttime, hours_low_05, hours_low_03, hours_anuria
        FROM uo_continuous
    ) uc
        ON co.stay_id = uc.stay_id
        AND co.starttime <= uc.charttime
        AND co.endtime >= uc.charttime
    GROUP BY co.stay_id, co.hr
)

, rrt_status AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(rrt.on_rrt) AS on_rrt
    FROM co
    LEFT JOIN rrt_active rrt
        ON co.stay_id = rrt.stay_id
            AND co.starttime < rrt.charttime
            AND co.endtime >= rrt.charttime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- SECTION 6: HEMOSTASIS (COAGULATION)
-- =================================================================
, plt AS (
    SELECT co.stay_id, co.hr
        , MIN(cbc.platelet) AS platelet_min
    FROM co
    LEFT JOIN mimiciv_derived.complete_blood_count cbc
        ON co.hadm_id = cbc.hadm_id
            AND co.starttime < cbc.charttime
            AND co.endtime >= cbc.charttime
    GROUP BY co.stay_id, co.hr
)

-- =================================================================
-- COMBINE ALL COMPONENTS
-- =================================================================
, scorecomp AS (
    SELECT
        co.stay_id
        , co.hr
        , co.starttime, co.endtime
        -- Brain/Neurological
        , gcs.gcs_min
        , bd.on_delirium_med
        -- Respiratory
        , rd.pf_novent_min
        , rd.pf_vent_min
        , rd.has_advanced_support
        , rd.ratio_type
        , rd.oxygen_ratio
        , ecmo.on_ecmo
        -- Cardiovascular
        , vs.mbp_min
        , vp.rate_norepinephrine
        , vp.rate_epinephrine
        , vs2.on_dopamine
        , vs2.on_dobutamine
        , vs2.on_vasopressin
        , vs2.on_phenylephrine
        , mech.has_mechanical_support
        -- Liver
        , bili.bilirubin_max
        -- Kidney
        , cr.creatinine_max
        , cr.potassium_max
        , bgm.ph_min
        , bgm.bicarbonate_min
        , rmc.meets_rrt_criteria
        , uod.max_hours_low_05
        , uod.max_hours_low_03
        , uod.max_hours_anuria
        , rrt.on_rrt
        -- Hemostasis
        , plt.platelet_min
    FROM co
    LEFT JOIN gcs
        ON co.stay_id = gcs.stay_id AND co.hr = gcs.hr
    LEFT JOIN brain_delirium bd
        ON co.stay_id = bd.stay_id AND co.hr = bd.hr
    LEFT JOIN respiratory_data rd
        ON co.stay_id = rd.stay_id AND co.hr = rd.hr
    LEFT JOIN ecmo_resp ecmo
        ON co.stay_id = ecmo.stay_id AND co.hr = ecmo.hr
    LEFT JOIN vs
        ON co.stay_id = vs.stay_id AND co.hr = vs.hr
    LEFT JOIN vaso_primary vp
        ON co.stay_id = vp.stay_id AND co.hr = vp.hr
    LEFT JOIN vaso_secondary vs2
        ON co.stay_id = vs2.stay_id AND co.hr = vs2.hr
    LEFT JOIN mech_support mech
        ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN bili
        ON co.stay_id = bili.stay_id AND co.hr = bili.hr
    LEFT JOIN cr
        ON co.stay_id = cr.stay_id AND co.hr = cr.hr
    LEFT JOIN bg_metabolic bgm
        ON co.stay_id = bgm.stay_id AND co.hr = bgm.hr
    LEFT JOIN rrt_metabolic_criteria rmc
        ON co.stay_id = rmc.stay_id AND co.hr = rmc.hr
    LEFT JOIN uo_max_durations uod
        ON co.stay_id = uod.stay_id AND co.hr = uod.hr
    LEFT JOIN rrt_status rrt
        ON co.stay_id = rrt.stay_id AND co.hr = rrt.hr
    LEFT JOIN plt
        ON co.stay_id = plt.stay_id AND co.hr = plt.hr
)

-- =================================================================
-- CALCULATE SOFA-2 SCORES
-- =================================================================
, scorecalc AS (
    SELECT scorecomp.*
        -- =====================================================
        -- BRAIN/NEUROLOGICAL
        -- =====================================================
        , CASE
            -- GCS 3-5 or severe motor response impairment = 4
            WHEN gcs_min <= 5 THEN 4
            -- GCS 6-8 = 3
            WHEN gcs_min >= 6 AND gcs_min <= 8 THEN 3
            -- GCS 9-12 = 2
            WHEN gcs_min >= 9 AND gcs_min <= 12 THEN 2
            -- GCS 13-14 OR on delirium meds = 1
            -- Note: Any patient on delirium medications gets minimum 1 point regardless of GCS
            WHEN (gcs_min >= 13 AND gcs_min <= 14) OR COALESCE(on_delirium_med, 0) = 1 THEN 1
            -- GCS 15 and no delirium meds = 0
            WHEN gcs_min = 15 AND COALESCE(on_delirium_med, 0) = 0 THEN 0
            -- Missing data = null
            WHEN gcs_min IS NULL AND COALESCE(on_delirium_med, 0) = 0 THEN NULL
            ELSE 0
        END AS brain

        -- =====================================================
        -- RESPIRATORY (FIXED VERSION - SOFA-2 Compliant)
        -- =====================================================
        , CASE
            -- 4 points: ECMO (regardless of ratio)
            WHEN on_ecmo = 1 THEN 4
            -- 4 points: Ratio ≤ threshold + advanced support
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 120  -- SF ratio threshold for 4 points
                    ELSE 75  -- PF ratio threshold for 4 points
                END
                AND rd.has_advanced_support = 1 THEN 4
            -- 3 points: Ratio ≤ threshold + advanced support
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 200  -- SF ratio threshold for 3 points
                    ELSE 150  -- PF ratio threshold for 3 points
                END
                AND rd.has_advanced_support = 1 THEN 3
            -- 2 points: Ratio ≤ threshold (SF: 250, PF: 225)
            WHEN rd.oxygen_ratio <=
                CASE
                    WHEN rd.ratio_type = 'SF' THEN 250  -- SF ratio threshold for 2 points
                    ELSE 225  -- PF ratio threshold for 2 points
                END THEN 2
            -- 1 point: Ratio ≤ 300 (same for both SF and PF)
            WHEN rd.oxygen_ratio <= 300 THEN 1
            -- 0 points: Ratio > 300 or no data
            WHEN rd.oxygen_ratio IS NULL THEN NULL
            ELSE 0
        END AS respiratory

        -- =====================================================
        -- CARDIOVASCULAR
        -- =====================================================
        , CASE
            -- 4 points: Mechanical circulatory support
            WHEN has_mechanical_support = 1 THEN 4
            -- Calculate combined NE+Epi dose (mcg/kg/min)
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.4 THEN 4
            -- 4 points: Medium dose NE+Epi + any other vasopressor
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4
                 AND (COALESCE(on_dopamine, 0) + COALESCE(on_dobutamine, 0)
                      + COALESCE(on_vasopressin, 0) + COALESCE(on_phenylephrine, 0) > 0)
                THEN 4
            -- 3 points: Medium dose NE+Epi (0.2-0.4 mcg/kg/min)
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4
                THEN 3
            -- 3 points: Low dose NE+Epi + any other vasopressor
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2
                 AND (COALESCE(on_dopamine, 0) + COALESCE(on_dobutamine, 0)
                      + COALESCE(on_vasopressin, 0) + COALESCE(on_phenylephrine, 0) > 0)
                THEN 3
            -- 2 points: Low dose NE+Epi (≤0.2 mcg/kg/min) OR any other vasopressor
            WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
                 AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2
                THEN 2
            -- 2 points: Any other vasopressor (binary indicators)
            WHEN COALESCE(on_dopamine, 0) + COALESCE(on_dobutamine, 0)
                 + COALESCE(on_vasopressin, 0) + COALESCE(on_phenylephrine, 0) > 0 THEN 2
            -- 1 point: MAP <70 without vasopressors
            WHEN mbp_min < 70 THEN 1
            -- 0 points: MAP ≥70 without vasopressors
            WHEN COALESCE(mbp_min, rate_norepinephrine, rate_epinephrine) IS NULL
                 AND (COALESCE(on_dopamine, 0) + COALESCE(on_dobutamine, 0)
                      + COALESCE(on_vasopressin, 0) + COALESCE(on_phenylephrine, 0) = 0) THEN NULL
            ELSE 0
        END AS cardiovascular

        -- =====================================================
        -- LIVER
        -- =====================================================
        , CASE
            -- SOFA-2: Changed thresholds to ≤ instead of <
            WHEN bilirubin_max > 12.0 THEN 4
            WHEN bilirubin_max > 6.0 AND bilirubin_max <= 12.0 THEN 3
            WHEN bilirubin_max > 3.0 AND bilirubin_max <= 6.0 THEN 2
            WHEN bilirubin_max > 1.2 AND bilirubin_max <= 3.0 THEN 1
            WHEN bilirubin_max IS NULL THEN NULL
            ELSE 0
        END AS liver

        -- =====================================================
        -- KIDNEY
        -- =====================================================
        , CASE
            -- 4 points: Receiving or fulfills criteria for RRT
            WHEN on_rrt = 1 THEN 4
            WHEN meets_rrt_criteria = 1 THEN 4
            -- 3 points: Creatinine >3.5 mg/dL OR severe oliguria/anuria
            WHEN creatinine_max > 3.5 THEN 3
            WHEN max_hours_low_03 >= 24 THEN 3  -- <0.3 ml/kg/h continuous ≥24h
            WHEN max_hours_anuria >= 12 THEN 3      -- Complete anuria ≥12h
            -- 2 points: Creatinine 2.0-3.5 mg/dL OR moderate oliguria (≥12h)
            WHEN creatinine_max > 2.0 AND creatinine_max <= 3.5 THEN 2
            WHEN max_hours_low_05 >= 12 THEN 2      -- <0.5 ml/kg/h continuous ≥12h
            -- 1 point: Creatinine 1.2-2.0 mg/dL OR mild oliguria (6-12h)
            WHEN creatinine_max > 1.2 AND creatinine_max <= 2.0 THEN 1
            WHEN max_hours_low_05 >= 6 AND max_hours_low_05 < 12 THEN 1  -- <0.5 ml/kg/h continuous 6-12h
            -- 0 points: Creatinine ≤1.2 mg/dL and adequate urine output
            WHEN creatinine_max <= 1.2 AND max_hours_low_05 = 0 THEN 0
            -- Null case: missing data
            WHEN COALESCE(creatinine_max, max_hours_low_05) IS NULL THEN NULL
            ELSE 0
        END AS kidney

        -- =====================================================
        -- HEMOSTASIS (COAGULATION)
        -- =====================================================
        , CASE
            -- SOFA-2: New thresholds
            WHEN platelet_min <= 50 THEN 4
            WHEN platelet_min <= 80 THEN 3
            WHEN platelet_min <= 100 THEN 2
            WHEN platelet_min <= 150 THEN 1
            WHEN platelet_min IS NULL THEN NULL
            ELSE 0
        END AS hemostasis

    FROM scorecomp
)

-- =================================================================
-- FINAL SCORE WITH 24-HOUR ROLLING WINDOW
-- =================================================================
, score_final AS (
    SELECT s.*
        -- Take max over last 24 hours for each component
        , COALESCE(MAX(brain) OVER w, 0) AS brain_24hours
        , COALESCE(MAX(respiratory) OVER w, 0) AS respiratory_24hours
        , COALESCE(MAX(cardiovascular) OVER w, 0) AS cardiovascular_24hours
        , COALESCE(MAX(liver) OVER w, 0) AS liver_24hours
        , COALESCE(MAX(kidney) OVER w, 0) AS kidney_24hours
        , COALESCE(MAX(hemostasis) OVER w, 0) AS hemostasis_24hours

        -- Total SOFA-2 score
        , COALESCE(MAX(brain) OVER w, 0)
        + COALESCE(MAX(respiratory) OVER w, 0)
        + COALESCE(MAX(cardiovascular) OVER w, 0)
        + COALESCE(MAX(liver) OVER w, 0)
        + COALESCE(MAX(kidney) OVER w, 0)
        + COALESCE(MAX(hemostasis) OVER w, 0)
        AS sofa2_24hours
    FROM scorecalc s
    WINDOW w AS (
        PARTITION BY stay_id
        ORDER BY hr
        ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING
    )
)

SELECT * FROM score_final
WHERE hr >= 0;
