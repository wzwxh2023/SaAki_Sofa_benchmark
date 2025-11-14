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
-- - Haloperidol (Haldol)
-- - Quetiapine (Seroquel)
-- - Olanzapine (Zyprexa)
-- - Risperidone (Risperdal)

-- Example CTE (to be used in main SOFA-2 query):
/*
WITH delirium_meds AS (
    SELECT
        ie.stay_id,
        pr.starttime,
        pr.stoptime,
        pr.drug AS delirium_drug,
        1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr
        ON ie.hadm_id = pr.hadm_id
    WHERE LOWER(pr.drug) LIKE '%haloperidol%'
       OR LOWER(pr.drug) LIKE '%quetiapine%'
       OR LOWER(pr.drug) LIKE '%olanzapine%'
       OR LOWER(pr.drug) LIKE '%risperidone%'
       OR LOWER(pr.drug) LIKE '%haldol%'
       OR LOWER(pr.drug) LIKE '%seroquel%'
       OR LOWER(pr.drug) LIKE '%zyprexa%'
       OR LOWER(pr.drug) LIKE '%risperdal%'
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
WITH advanced_respiratory_support AS (
    SELECT
        stay_id,
        starttime,
        endtime,
        ventilation_status,
        CASE
            WHEN ventilation_status IN ('InvasiveVent', 'Tracheostomy') THEN 'IMV'
            WHEN ventilation_status = 'NonInvasiveVent' THEN 'NIV'
            WHEN ventilation_status = 'HFNC' THEN 'HFNC'
            ELSE 'Other'
        END AS support_type,
        1 AS has_advanced_support
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')
)
*/

-- For CPAP/BiPAP detection from chartevents:
-- itemid 227287: CPAP
-- itemid 227288: BiPAP

/*
WITH cpap_bipap AS (
    SELECT
        stay_id,
        charttime AS starttime,
        charttime AS endtime,
        CASE
            WHEN itemid = 227287 THEN 'CPAP'
            WHEN itemid = 227288 THEN 'BiPAP'
        END AS support_type,
        1 AS has_advanced_support
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (227287, 227288)
      AND value IS NOT NULL
)
*/

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
    SELECT
        ie.stay_id,
        ce.charttime,
        CASE
            WHEN ce.itemid IN (228001, 229270, 229272) THEN 'ECMO'
            WHEN ce.itemid IN (228000, 224797, 224798) THEN 'IABP'
            WHEN ce.itemid IN (224828, 224829) THEN 'Impella'
            WHEN LOWER(ce.value) LIKE '%lvad%' THEN 'LVAD'
            WHEN LOWER(ce.value) LIKE '%ecmo%' THEN 'ECMO'
            WHEN LOWER(ce.value) LIKE '%iabp%' THEN 'IABP'
            WHEN LOWER(ce.value) LIKE '%impella%' THEN 'Impella'
        END AS device_type,
        1 AS has_mechanical_support
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_icu.chartevents ce
        ON ie.stay_id = ce.stay_id
    WHERE ce.itemid IN (228001, 229270, 229272, 228000, 224797, 224798, 224828, 224829)
       OR (ce.itemid IN (
               SELECT itemid FROM mimiciv_icu.d_items
               WHERE LOWER(label) LIKE '%ecmo%'
                  OR LOWER(label) LIKE '%iabp%'
                  OR LOWER(label) LIKE '%impella%'
                  OR LOWER(label) LIKE '%lvad%'
           ) AND ce.value IS NOT NULL)
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

-- Metabolic criteria for RRT indication
/*
WITH rrt_metabolic_criteria AS (
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
    FROM icustay_hourly co
    LEFT JOIN (
        SELECT stay_id, charttime, MAX(creatinine) AS creatinine_max
        FROM mimiciv_derived.chemistry
        GROUP BY stay_id, charttime
    ) cr ON co.stay_id = cr.stay_id
    LEFT JOIN (
        SELECT stay_id, charttime, MAX(potassium) AS potassium_max
        FROM mimiciv_derived.chemistry
        GROUP BY stay_id, charttime
    ) k ON co.stay_id = k.stay_id
    LEFT JOIN (
        SELECT stay_id, charttime, MIN(ph) AS ph_min, MIN(bicarbonate) AS bicarbonate_min
        FROM mimiciv_derived.bg
        WHERE specimen = 'ART.'
        GROUP BY stay_id, charttime
    ) bg ON co.stay_id = bg.stay_id
)
*/

-- =================================================================
-- SECTION 5: ADDITIONAL VASOPRESSORS
-- =================================================================
-- Additional vasopressors for SOFA-2 Cardiovascular scoring:
-- - Vasopressin (Pitressin)
-- - Phenylephrine (Neo-Synephrine)

-- MIMIC-IV already has derived tables for norepi, epi, dopamine, dobutamine
-- Need to add vasopressin and phenylephrine

-- Vasopressin itemids: 222315 (inputevents_mv)
-- Phenylephrine itemids: 221749 (inputevents_mv)

/*
WITH vasopressin AS (
    SELECT
        stay_id,
        starttime,
        endtime,
        rate AS vasopressin_rate,  -- units/min
        amount,
        amountuom
    FROM mimiciv_icu.inputevents
    WHERE itemid = 222315
      AND rate IS NOT NULL
      AND rate > 0
)

, phenylephrine AS (
    SELECT
        ie.stay_id,
        mv.starttime,
        mv.endtime,
        mv.rate AS phenylephrine_rate_raw,  -- mcg/min
        -- Convert to mcg/kg/min
        mv.rate / NULLIF(wt.weight, 0) AS phenylephrine_rate  -- mcg/kg/min
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_icu.inputevents mv
        ON ie.stay_id = mv.stay_id
    LEFT JOIN mimiciv_derived.first_day_weight wt
        ON ie.stay_id = wt.stay_id
    WHERE mv.itemid = 221749
      AND mv.rate IS NOT NULL
      AND mv.rate > 0
)
*/

-- =================================================================
-- SECTION 6: URINE OUTPUT WITH WEIGHT
-- =================================================================
-- SOFA-2 kidney scoring uses weight-based urine output (ml/kg/h)
-- Need patient weight for calculation

/*
WITH uo_weight_based AS (
    SELECT
        uo.stay_id,
        uo.charttime,
        uo.urineoutput,
        wt.weight,
        -- Calculate ml/kg/h over different time windows
        -- 6-hour window
        SUM(uo.urineoutput) OVER (
            PARTITION BY uo.stay_id
            ORDER BY uo.charttime
            RANGE BETWEEN INTERVAL '6' HOUR PRECEDING AND CURRENT ROW
        ) / (wt.weight * 6) AS uo_ml_kg_h_6h,
        -- 12-hour window
        SUM(uo.urineoutput) OVER (
            PARTITION BY uo.stay_id
            ORDER BY uo.charttime
            RANGE BETWEEN INTERVAL '12' HOUR PRECEDING AND CURRENT ROW
        ) / (wt.weight * 12) AS uo_ml_kg_h_12h,
        -- 24-hour window
        SUM(uo.urineoutput) OVER (
            PARTITION BY uo.stay_id
            ORDER BY uo.charttime
            RANGE BETWEEN INTERVAL '24' HOUR PRECEDING AND CURRENT ROW
        ) / (wt.weight * 24) AS uo_ml_kg_h_24h
    FROM mimiciv_derived.urine_output uo
    LEFT JOIN mimiciv_derived.first_day_weight wt
        ON uo.stay_id = wt.stay_id
    WHERE wt.weight IS NOT NULL AND wt.weight > 0
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
WHERE LOWER(drug) LIKE '%haloperidol%'
   OR LOWER(drug) LIKE '%quetiapine%'
   OR LOWER(drug) LIKE '%olanzapine%'
   OR LOWER(drug) LIKE '%risperidone%';
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
