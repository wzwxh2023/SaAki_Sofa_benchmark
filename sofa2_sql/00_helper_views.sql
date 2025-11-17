-- ------------------------------------------------------------------
-- Title: SOFA-2 Helper Views
-- Description: Helper views for SOFA-2 specific components
--
-- This script creates materialized views or CTEs for:
-- 1. Delirium medications (for Brain/Neurological scoring)
-- 2. Advanced respiratory support (for Respiratory scoring)
-- 3. Mechanical circulatory support (for Cardiovascular scoring)
-- 4. RRT with metabolic criteria (for Kidney scoring)
-- 5. Additional vasopressors (vasopressin, phenylephrine)
-- 6. Liver function tests (for Liver scoring)
-- 7. Hemostasis parameters (for Coagulation scoring)
-- 8. Weight-based urine output analysis (for Kidney scoring)
--
-- Reference: Ranzani OT, et al. JAMA 2025
-- ------------------------------------------------------------------

-- Note: For PostgreSQL compatibility (MIMIC-IV), we'll create these
-- as CTEs within the main query. For BigQuery, adapt accordingly.

-- =================================================================
-- SECTION 1: DELIRIUM MEDICATIONS
-- =================================================================
-- Medications used to treat delirium
-- If patient is on any of these, Brain score is minimum 1 point

-- Common delirium medications in MIMIC-IV:
-- Generic names: Haloperidol, Quetiapine, Olanzapine, Risperidone, Ziprasidone
-- Brand names: Haldol, Seroquel, Zyprexa, Risperdal, Geodon

-- Example CTE (to be used in main SOFA-2 query):
/*
WITH delirium_meds AS (
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

-- Brain delirium detection by hour (simplified version)
, brain_delirium AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN pr.starttime::date <= co.endtime::date
            AND COALESCE(pr.stoptime::date, co.endtime::date) >= co.starttime::date
            THEN 1 ELSE 0
        END) AS on_delirium_med
    FROM co
    LEFT JOIN mimiciv_hosp.prescriptions pr
        ON co.hadm_id = pr.hadm_id
    WHERE (LOWER(pr.drug) LIKE '%haloperidol%' OR LOWER(pr.drug) LIKE '%haldol%'
           OR LOWER(pr.drug) LIKE '%quetiapine%' OR LOWER(pr.drug) LIKE '%seroquel%'
           OR LOWER(pr.drug) LIKE '%olanzapine%' OR LOWER(pr.drug) LIKE '%zyprexa%'
           OR LOWER(pr.drug) LIKE '%risperidone%' OR LOWER(pr.drug) LIKE '%risperdal%'
           OR LOWER(pr.drug) LIKE '%ziprasidone%' OR LOWER(pr.drug) LIKE '%geodon%')
    GROUP BY co.stay_id, co.hr
)
*/

-- =================================================================
-- SECTION 2: ADVANCED RESPIRATORY SUPPORT
-- =================================================================
-- Advanced respiratory support for SOFA-2 Respiratory scoring:
-- - High-flow nasal cannula (HFNC)
-- - Continuous positive airway pressure (CPAP)
-- - Bilevel positive airway pressure (BiPAP)
-- - Non-invasive ventilation (NIV)
-- - Invasive mechanical ventilation (IMV)
-- - Long-term home ventilation

-- In MIMIC-IV, use mimiciv_derived.ventilation table
-- ventilation_status values: 'InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy'

-- Example CTE:
/*
WITH advanced_resp_support AS (
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
*/

-- NOTE: CPAP/BiPAP detection has been integrated into advanced_resp_support CTE
-- above using correct MIMIC-IV itemids (227577-227583):
-- 227583: CPAP/Autoset
-- 227577-227582: Various BiPAP modes

-- =================================================================
-- SECTION 3: MECHANICAL CIRCULATORY SUPPORT
-- =================================================================
-- Mechanical circulatory support for Cardiovascular scoring (automatic 4 points):
-- - ECMO (veno-arterial)
-- - IABP (intra-aortic balloon pump)
-- - LVAD (left ventricular assist device)
-- - Impella (microaxial flow pump)

-- MIMIC-IV itemids for mechanical support:
-- ECMO: 228001, 229270, 229272 (chartevents)
-- IABP: 228000, 224797, 224798 (chartevents)
-- Impella: Can be found in procedureevents or chartevents

-- Example CTE:
/*
WITH mechanical_support AS (
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
*/

-- ECMO detection for respiratory scoring
/*
, ecmo_resp AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN ce.itemid IN (229815, 229816) AND ce.valuenum = 1 THEN 1
            ELSE 0
        END) AS on_ecmo
    FROM co
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
        AND co.starttime <= ce.charttime
        AND co.endtime >= ce.charttime
    WHERE ce.itemid IN (229815, 229816)
    GROUP BY co.stay_id, co.hr
)
*/

-- Alternative: Check procedureevents
/*
WITH mechanical_support_proc AS (
    SELECT
        stay_id,
        starttime,
        endtime,
        CASE
            WHEN LOWER(itemid::text) LIKE '%ecmo%' THEN 'ECMO'
            WHEN LOWER(itemid::text) LIKE '%iabp%' THEN 'IABP'
            WHEN LOWER(itemid::text) LIKE '%impella%' THEN 'Impella'
            WHEN LOWER(itemid::text) LIKE '%lvad%' THEN 'LVAD'
        END AS device_type,
        1 AS has_mechanical_support
    FROM mimiciv_icu.procedureevents
    WHERE LOWER(itemid::text) LIKE '%ecmo%'
       OR LOWER(itemid::text) LIKE '%iabp%'
       OR LOWER(itemid::text) LIKE '%impella%'
       OR LOWER(itemid::text) LIKE '%lvad%'
)
*/

-- =================================================================
-- SECTION 4: RRT WITH METABOLIC CRITERIA
-- =================================================================
-- RRT criteria for SOFA-2 Kidney scoring (4 points):
-- 1. Actually receiving RRT, OR
-- 2. Meets RRT initiation criteria:
--    - Creatinine >1.2 mg/dL (or oliguria <0.3 ml/kg/h >6h)
--    - PLUS at least one of:
--      a) Potassium ≥6.0 mmol/L
--      b) Metabolic acidosis: pH ≤7.2 AND bicarbonate ≤12 mmol/L

-- RRT detection in MIMIC-IV:
-- - mimiciv_derived.rrt table
-- - procedureevents with RRT-related itemids
-- - inputevents/outputevents for dialysate

/*
WITH rrt_actual AS (
    -- Patients actually on RRT
    SELECT
        stay_id,
        charttime,
        dialysis_present,
        dialysis_active,
        dialysis_type,
        1 AS on_rrt
    FROM mimiciv_derived.rrt
    WHERE dialysis_active = 1
)
*/

-- Active RRT detection
/*
WITH rrt_active AS (
    SELECT
        stay_id,
        charttime,
        dialysis_active AS on_rrt
    FROM mimiciv_derived.rrt
    WHERE dialysis_active = 1
)

-- Metabolic criteria for RRT indication (comprehensive version)
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

-- RRT status by hour
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
*/

-- =================================================================
-- SECTION 5: LIVER FUNCTION
-- =================================================================
-- Liver function tests for SOFA-2 Liver scoring:
-- Bilirubin levels determine liver component score

-- Liver function detection
/*
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
*/

-- =================================================================
-- SECTION 6: HEMOSTASIS (COAGULATION)
-- =================================================================
-- Hemostasis parameters for SOFA-2 Hemostasis scoring:
-- Platelet count determines coagulation component score

-- Hemostasis detection
/*
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
*/

-- =================================================================
-- SECTION 7: ADDITIONAL VASOPRESSORS
-- =================================================================
-- Additional vasopressors for SOFA-2 Cardiovascular scoring:
-- - Vasopressin (Pitressin) - binary indicator (any dose = 2 points)
-- - Phenylephrine (Neo-Synephrine) - binary indicator (any dose = 2 points)
-- - Dopamine - binary indicator (any dose = 2 points)
-- - Dobutamine - binary indicator (any dose = 2 points)

-- Key insight: Only Norepinephrine and Epinephrine require dose thresholds
-- All other vasopressors are binary (presence/absence) for SOFA-2 scoring

/*
-- Primary vasopressors (require dose thresholds) - simplified version
WITH vaso_primary AS (
    SELECT
        co.stay_id, co.hr,
        MAX(va.norepinephrine) AS rate_norepinephrine,
        MAX(va.epinephrine) AS rate_epinephrine
    FROM co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND co.starttime <= va.starttime
        AND co.endtime >= COALESCE(va.endtime, co.endtime)
    GROUP BY co.stay_id, co.hr
)

-- Secondary vasopressors (binary indicators)
, vaso_secondary AS (
    SELECT
        co.stay_id, co.hr,
        -- Any dose of dopamine (binary: 0/1)
        CASE WHEN MAX(dop.vaso_rate) > 0 THEN 1 ELSE 0 END AS on_dopamine,
        -- Any dose of dobutamine (binary: 0/1)
        CASE WHEN MAX(dob.vaso_rate) > 0 THEN 1 ELSE 0 END AS on_dobutamine,
        -- Any dose of vasopressin (binary: 0/1)
        CASE WHEN MAX(vas.rate) > 0 THEN 1 ELSE 0 END AS on_vasopressin,
        -- Any dose of phenylephrine (binary: 0/1)
        CASE WHEN MAX(phen.rate) > 0 THEN 1 ELSE 0 END AS on_phenylephrine
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

-- Mechanical support detection for cardiovascular scoring
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
*/

-- SOFA-2 Cardiovascular Scoring Logic:
/*
CASE
    -- 4 points: Mechanical support or high-dose NE+Epi (>0.4 mcg/kg/min)
    WHEN has_mechanical_support = 1 THEN 4
    WHEN (rate_norepinephrine + rate_epinephrine) > 0.4 THEN 4
    -- 4 points: Medium dose NE+Epi (0.2-0.4) + any other vasopressor
    WHEN (rate_norepinephrine + rate_epinephrine) > 0.2
         AND (rate_norepinephrine + rate_epinephrine) <= 0.4
         AND (on_dopamine + on_dobutamine + on_vasopressin + on_phenylephrine > 0) THEN 4
    -- 3 points: Medium dose NE+Epi (0.2-0.4 mcg/kg/min)
    WHEN (rate_norepinephrine + rate_epinephrine) > 0.2
         AND (rate_norepinephrine + rate_epinephrine) <= 0.4 THEN 3
    -- 3 points: Low dose NE+Epi (≤0.2) + any other vasopressor
    WHEN (rate_norepinephrine + rate_epinephrine) > 0
         AND (rate_norepinephrine + rate_epinephrine) <= 0.2
         AND (on_dopamine + on_dobutamine + on_vasopressin + on_phenylephrine > 0) THEN 3
    -- 2 points: Low dose NE+Epi (≤0.2) or any other vasopressor
    WHEN (rate_norepinephrine + rate_epinephrine) > 0
         AND (rate_norepinephrine + rate_epinephrine) <= 0.2 THEN 2
    WHEN (on_dopamine + on_dobutamine + on_vasopressin + on_phenylephrine) > 0 THEN 2
    -- 1 point: MAP <70 without vasopressors
    WHEN mbp_min < 70 THEN 1
    -- 0 points: MAP ≥70 without vasopressors
    ELSE 0
END AS cardiovascular
*/

-- SOFA-2 Liver Scoring Logic:
/*
CASE
    -- SOFA-2: Changed thresholds to ≤ instead of <
    WHEN bilirubin_max > 12.0 THEN 4
    WHEN bilirubin_max > 6.0 AND bilirubin_max <= 12.0 THEN 3
    WHEN bilirubin_max > 3.0 AND bilirubin_max <= 6.0 THEN 2
    WHEN bilirubin_max > 1.2 AND bilirubin_max <= 3.0 THEN 1
    WHEN bilirubin_max IS NULL THEN NULL
    ELSE 0
END AS liver
*/

-- SOFA-2 Kidney Scoring Logic:
/*
CASE
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
*/

-- SOFA-2 Hemostasis Scoring Logic:
/*
CASE
    -- SOFA-2: New thresholds
    WHEN platelet_min <= 50 THEN 4
    WHEN platelet_min <= 80 THEN 3
    WHEN platelet_min <= 100 THEN 2
    WHEN platelet_min <= 150 THEN 1
    WHEN platelet_min IS NULL THEN NULL
    ELSE 0
END AS hemostasis
*/

-- =================================================================
-- SECTION 8: URINE OUTPUT WITH WEIGHT
-- =================================================================
-- SOFA-2 kidney scoring uses weight-based urine output (ml/kg/h)
-- Need patient weight for calculation

-- Patient weight (needed for weight-based UO only)
/*
WITH patient_weight AS (
    SELECT
        stay_id,
        weight
    FROM mimiciv_derived.first_day_weight
    WHERE weight IS NOT NULL AND weight > 0
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
)

-- Step 6: Get maximum continuous durations for each hour
, uo_max_durations AS (
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
*/

-- =================================================================
-- VALIDATION QUERIES
-- =================================================================

-- Check delirium medication prevalence
/*
SELECT
    COUNT(DISTINCT stay_id) AS patients_on_delirium_meds,
    COUNT(DISTINCT stay_id) * 100.0 / (SELECT COUNT(*) FROM mimiciv_icu.icustays) AS prevalence_pct
FROM mimiciv_hosp.prescriptions
WHERE (LOWER(drug) LIKE '%haloperidol%' OR LOWER(drug) LIKE '%haldol%'
   OR LOWER(drug) LIKE '%quetiapine%' OR LOWER(drug) LIKE '%seroquel%'
   OR LOWER(drug) LIKE '%olanzapine%' OR LOWER(drug) LIKE '%zyprexa%'
   OR LOWER(drug) LIKE '%risperidone%' OR LOWER(drug) LIKE '%risperdal%'
   OR LOWER(drug) LIKE '%ziprasidone%' OR LOWER(drug) LIKE '%geodon%');
*/

-- Check advanced respiratory support prevalence
/*
SELECT
    ventilation_status,
    COUNT(*) AS n_episodes,
    COUNT(DISTINCT stay_id) AS n_patients
FROM mimiciv_derived.ventilation
GROUP BY ventilation_status
ORDER BY n_episodes DESC;
*/

-- Check mechanical support prevalence
/*
SELECT
    'ECMO' AS device,
    COUNT(DISTINCT stay_id) AS n_patients
FROM mimiciv_icu.chartevents
WHERE itemid IN (228001, 229270, 229272)
UNION ALL
SELECT
    'IABP' AS device,
    COUNT(DISTINCT stay_id) AS n_patients
FROM mimiciv_icu.chartevents
WHERE itemid IN (228000, 224797, 224798);
*/

-- =================================================================
-- NOTES FOR IMPLEMENTATION
-- =================================================================

-- 1. All of these CTEs should be incorporated into the main SOFA-2
--    calculation queries (sofa2.sql and first_day_sofa2.sql)

-- 2. For performance, consider creating materialized views for:
--    - delirium_meds
--    - advanced_respiratory_support
--    - mechanical_support
--    - rrt_with_criteria

-- 3. Weight data is critical for SOFA-2 kidney scoring
--    - Use first_day_weight as approximation
--    - Or derive daily weight if available

-- 4. Time alignment is critical:
--    - Medications: Check if active during scoring window
--    - Devices: Check if in use during scoring window
--    - Labs: Use values within scoring window

-- 5. Missing data handling:
--    - If weight missing: Cannot calculate weight-based UO (use creatinine only)
--    - If no delirium meds data: Assume none (score based on GCS only)
--    - If no device data: Assume none

-- =================================================================
-- END OF HELPER VIEWS
-- =================================================================
