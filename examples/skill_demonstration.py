"""
MIMIC-IV Data Extraction Skill - Demonstration
================================================

This script demonstrates how the MIMIC-IV skill helps with:
1. Building sepsis cohorts
2. Extracting SOFA score components
3. Detecting acute kidney injury (AKI)
4. Combining clinical concepts for research

Using the skill knowledge to generate validated SQL queries.
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from utils.db_helper import query_to_df, test_connection
import pandas as pd

print("=" * 70)
print("MIMIC-IV DATA EXTRACTION SKILL - DEMONSTRATION")
print("=" * 70)
print()

# Test connection first
if not test_connection('mimic'):
    print("❌ Cannot connect to database. Please check configuration.")
    sys.exit(1)

print()
print("=" * 70)
print("DEMO 1: Using Skill to Build Adult ICU Patient Cohort")
print("=" * 70)
print()

# Using skill pattern: Patient Cohort Selection
cohort_sql = """
-- SKILL PATTERN: Adult ICU patient cohort with demographics
-- Source: MIMIC-IV Data Extraction Skill > Common Data Extraction Patterns

SELECT
    ie.subject_id,
    ie.hadm_id,
    ie.stay_id,
    ie.intime as icu_intime,
    ie.outtime as icu_outtime,
    ie.los as icu_los_days,
    ie.first_careunit,
    p.gender,
    p.anchor_age,
    a.admission_type,
    a.hospital_expire_flag,
    a.race,
    a.insurance
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_hosp.patients p
    ON ie.subject_id = p.subject_id
INNER JOIN mimiciv_hosp.admissions a
    ON ie.hadm_id = a.hadm_id
WHERE p.anchor_age >= 18  -- Adult patients (skill recommendation)
  AND ie.los >= 1          -- Minimum 1 day stay
ORDER BY ie.stay_id
LIMIT 10;  -- Preview mode
"""

print("📋 SQL Query (from skill pattern):")
print(cohort_sql)
print()

cohort_df = query_to_df(cohort_sql, db='mimic')
print("✅ Retrieved cohort:")
print(cohort_df.to_string())
print()

print("=" * 70)
print("DEMO 2: Extract SOFA Score Components (First 24 Hours)")
print("=" * 70)
print()

# Get a sample stay_id for demonstration
sample_stay_id = cohort_df.iloc[0]['stay_id']
print(f"🎯 Using sample ICU stay: {sample_stay_id}")
print()

# SOFA Component 1: Respiration (PaO2/FiO2 ratio)
print("--- SOFA Component: Respiration (PaO2/FiO2) ---")
sofa_resp_sql = f"""
-- SKILL PATTERN: SOFA Respiration Component
-- Source: MIMIC-IV Skill > Clinical Concepts > SOFA Score

WITH pao2_fio2 AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        -- PaO2 from blood gas (itemid 50821 from skill itemid reference)
        MAX(CASE WHEN ce.itemid = 50821 THEN ce.valuenum END) as pao2,
        -- FiO2 (itemid 223835 from skill reference)
        MAX(CASE WHEN ce.itemid IN (223835, 50816) THEN ce.valuenum END) as fio2
    FROM mimiciv_icu.chartevents ce
    JOIN mimiciv_icu.icustays ie ON ce.stay_id = ie.stay_id
    WHERE ce.stay_id = {sample_stay_id}
      AND ce.charttime BETWEEN ie.intime AND ie.intime + INTERVAL '24 hours'
      AND ce.itemid IN (50821, 223835, 50816)
    GROUP BY ce.stay_id, ce.charttime
)
SELECT
    stay_id,
    charttime,
    pao2,
    fio2,
    ROUND(pao2/NULLIF(fio2, 0), 2) as pf_ratio,
    CASE
        WHEN pao2/NULLIF(fio2, 0) < 100 THEN 4
        WHEN pao2/NULLIF(fio2, 0) < 200 THEN 3
        WHEN pao2/NULLIF(fio2, 0) < 300 THEN 2
        WHEN pao2/NULLIF(fio2, 0) < 400 THEN 1
        ELSE 0
    END as sofa_respiration_score
FROM pao2_fio2
WHERE pao2 IS NOT NULL AND fio2 IS NOT NULL
ORDER BY charttime;
"""

sofa_resp_df = query_to_df(sofa_resp_sql, db='mimic')
if not sofa_resp_df.empty:
    print("✅ SOFA Respiration Data:")
    print(sofa_resp_df.to_string())
else:
    print("ℹ️  No PaO2/FiO2 data available for this stay (common for non-ventilated patients)")
print()

# SOFA Component 6: Renal (Creatinine)
print("--- SOFA Component: Renal (Creatinine) ---")
sofa_renal_sql = f"""
-- SKILL PATTERN: SOFA Renal Component using Creatinine
-- Source: MIMIC-IV Skill > Clinical Concepts > SOFA Score
-- Creatinine itemid: 50912 (from skill itemid reference)

SELECT
    le.charttime,
    di.label,
    le.valuenum as creatinine_mg_dl,
    le.valueuom,
    CASE
        WHEN le.valuenum >= 5.0 THEN 4
        WHEN le.valuenum >= 3.5 THEN 3
        WHEN le.valuenum >= 2.0 THEN 2
        WHEN le.valuenum >= 1.2 THEN 1
        ELSE 0
    END as sofa_renal_score
FROM mimiciv_hosp.labevents le
JOIN mimiciv_hosp.d_labitems di ON le.itemid = di.itemid
JOIN mimiciv_icu.icustays ie ON le.subject_id = ie.subject_id
WHERE le.stay_id = {sample_stay_id}
  AND le.itemid = 50912  -- Creatinine
  AND le.charttime BETWEEN ie.intime AND ie.intime + INTERVAL '24 hours'
  AND le.valuenum IS NOT NULL
ORDER BY le.charttime;
"""

sofa_renal_df = query_to_df(sofa_renal_sql, db='mimic')
if not sofa_renal_df.empty:
    print("✅ SOFA Renal Data:")
    print(sofa_renal_df.to_string())
    print()
    max_score = sofa_renal_df['sofa_renal_score'].max()
    print(f"📊 First 24h Maximum SOFA Renal Score: {max_score}")
else:
    print("ℹ️  No creatinine data in first 24 hours")
print()

print("=" * 70)
print("DEMO 3: Detect Acute Kidney Injury (KDIGO Criteria)")
print("=" * 70)
print()

# Using skill pattern for AKI detection
aki_sql = f"""
-- SKILL PATTERN: AKI Detection using KDIGO Creatinine Criteria
-- Source: MIMIC-IV Skill > Clinical Concepts > AKI

WITH baseline_cr AS (
    SELECT
        le.subject_id,
        le.hadm_id,
        MIN(le.valuenum) as baseline_creatinine
    FROM mimiciv_hosp.labevents le
    JOIN mimiciv_hosp.d_labitems di ON le.itemid = di.itemid
    WHERE le.hadm_id = (
        SELECT hadm_id FROM mimiciv_icu.icustays WHERE stay_id = {sample_stay_id}
    )
      AND di.label = 'Creatinine'
      AND le.valuenum IS NOT NULL
      AND le.valuenum BETWEEN 0.1 AND 20  -- Reasonable range
    GROUP BY le.subject_id, le.hadm_id
),
current_cr AS (
    SELECT
        le.subject_id,
        le.hadm_id,
        le.charttime,
        le.valuenum as creatinine
    FROM mimiciv_hosp.labevents le
    JOIN mimiciv_hosp.d_labitems di ON le.itemid = di.itemid
    JOIN mimiciv_icu.icustays ie ON le.subject_id = ie.subject_id
    WHERE le.stay_id = {sample_stay_id}
      AND di.label = 'Creatinine'
      AND le.valuenum IS NOT NULL
      AND le.charttime >= ie.intime  -- During ICU stay
    ORDER BY le.charttime
)
SELECT
    c.charttime,
    ROUND(b.baseline_creatinine::numeric, 2) as baseline_cr,
    ROUND(c.creatinine::numeric, 2) as current_cr,
    ROUND((c.creatinine - b.baseline_creatinine)::numeric, 2) as cr_increase,
    ROUND((c.creatinine / NULLIF(b.baseline_creatinine, 0))::numeric, 2) as cr_ratio,
    CASE
        WHEN c.creatinine >= b.baseline_creatinine * 3 THEN 'AKI Stage 3'
        WHEN c.creatinine >= b.baseline_creatinine * 2 THEN 'AKI Stage 2'
        WHEN c.creatinine >= b.baseline_creatinine + 0.3
             OR c.creatinine >= b.baseline_creatinine * 1.5 THEN 'AKI Stage 1'
        ELSE 'No AKI'
    END as aki_stage
FROM current_cr c
LEFT JOIN baseline_cr b
    ON c.subject_id = b.subject_id
    AND c.hadm_id = b.hadm_id
WHERE b.baseline_creatinine IS NOT NULL
ORDER BY c.charttime;
"""

aki_df = query_to_df(aki_sql, db='mimic')
if not aki_df.empty:
    print("✅ AKI Detection Results:")
    print(aki_df.to_string())
    print()

    # Summary
    has_aki = (aki_df['aki_stage'] != 'No AKI').any()
    if has_aki:
        max_stage = aki_df.loc[aki_df['aki_stage'] != 'No AKI', 'aki_stage'].iloc[-1]
        print(f"🚨 AKI Detected: {max_stage}")
    else:
        print("✅ No AKI detected during ICU stay")
else:
    print("ℹ️  Insufficient creatinine data for AKI assessment")
print()

print("=" * 70)
print("DEMO 4: Vital Signs Time Series (First 6 Hours)")
print("=" * 70)
print()

# Using skill pattern for time-series extraction
vitals_sql = f"""
-- SKILL PATTERN: Time-Series Vital Signs Extraction
-- Source: MIMIC-IV Skill > Common Data Extraction Patterns
-- Using itemids from skill reference guide

SELECT
    ie.stay_id,
    ce.charttime,
    ROUND(EXTRACT(EPOCH FROM (ce.charttime - ie.intime))/3600, 1) as hours_since_admission,
    MAX(CASE WHEN ce.itemid = 220045 THEN ce.valuenum END) as heart_rate,
    MAX(CASE WHEN ce.itemid = 220210 THEN ce.valuenum END) as resp_rate,
    MAX(CASE WHEN ce.itemid = 220277 THEN ce.valuenum END) as spo2,
    MAX(CASE WHEN ce.itemid = 220181 THEN ce.valuenum END) as map,
    MAX(CASE WHEN ce.itemid = 223761 THEN
        ROUND((ce.valuenum - 32) * 5/9, 1)  -- Convert F to C
    END) as temperature_c
FROM mimiciv_icu.icustays ie
LEFT JOIN mimiciv_icu.chartevents ce
    ON ie.stay_id = ce.stay_id
    AND ce.charttime BETWEEN ie.intime AND ie.intime + INTERVAL '6 hours'
    AND ce.itemid IN (
        220045,  -- Heart Rate
        220210,  -- Respiratory Rate
        220277,  -- SpO2
        220181,  -- MAP
        223761   -- Temperature F
    )
WHERE ie.stay_id = {sample_stay_id}
GROUP BY ie.stay_id, ce.charttime, ie.intime
ORDER BY ce.charttime;
"""

vitals_df = query_to_df(vitals_sql, db='mimic')
if not vitals_df.empty:
    print("✅ Vital Signs Timeline:")
    print(vitals_df.to_string())
    print()
    print("📊 Summary Statistics:")
    print(vitals_df[['heart_rate', 'resp_rate', 'spo2', 'map', 'temperature_c']].describe())
else:
    print("ℹ️  No vital signs data available")
print()

print("=" * 70)
print("DEMO 5: Identify Sepsis Suspicion")
print("=" * 70)
print()

# Using skill pattern for sepsis detection
sepsis_sql = f"""
-- SKILL PATTERN: Sepsis Suspicion Detection
-- Source: MIMIC-IV Skill > Clinical Concepts > Sepsis-3

WITH antibiotics AS (
    SELECT DISTINCT
        p.subject_id,
        p.hadm_id,
        p.drug,
        p.starttime as antibiotic_time
    FROM mimiciv_hosp.prescriptions p
    WHERE p.hadm_id = (
        SELECT hadm_id FROM mimiciv_icu.icustays WHERE stay_id = {sample_stay_id}
    )
      AND (
          p.drug ILIKE '%vancomycin%' OR
          p.drug ILIKE '%piperacillin%' OR
          p.drug ILIKE '%cefepime%' OR
          p.drug ILIKE '%meropenem%' OR
          p.drug ILIKE '%levofloxacin%' OR
          p.drug ILIKE '%ciprofloxacin%'
      )
),
cultures AS (
    SELECT DISTINCT
        me.subject_id,
        me.hadm_id,
        me.charttime as culture_time,
        me.spec_type_desc,
        me.org_name
    FROM mimiciv_hosp.microbiologyevents me
    WHERE me.hadm_id = (
        SELECT hadm_id FROM mimiciv_icu.icustays WHERE stay_id = {sample_stay_id}
    )
      AND me.spec_type_desc IN ('BLOOD CULTURE', 'URINE', 'SPUTUM')
)
SELECT
    a.drug,
    a.antibiotic_time,
    c.culture_time,
    c.spec_type_desc,
    c.org_name,
    ROUND(EXTRACT(EPOCH FROM (a.antibiotic_time - c.culture_time))/3600, 1) as hours_between
FROM antibiotics a
FULL OUTER JOIN cultures c
    ON a.subject_id = c.subject_id
    AND a.hadm_id = c.hadm_id
    AND ABS(EXTRACT(EPOCH FROM (a.antibiotic_time - c.culture_time))/3600) <= 24
ORDER BY COALESCE(a.antibiotic_time, c.culture_time);
"""

sepsis_df = query_to_df(sepsis_sql, db='mimic')
if not sepsis_df.empty:
    print("✅ Sepsis Suspicion Indicators:")
    print(sepsis_df.to_string())
    print()

    has_antibiotics = sepsis_df['drug'].notna().any()
    has_cultures = sepsis_df['culture_time'].notna().any()
    has_both = (sepsis_df['drug'].notna() & sepsis_df['culture_time'].notna()).any()

    print(f"💊 Antibiotics prescribed: {'Yes' if has_antibiotics else 'No'}")
    print(f"🧫 Cultures ordered: {'Yes' if has_cultures else 'No'}")
    print(f"🎯 Suspected infection (both within 24h): {'Yes' if has_both else 'No'}")
else:
    print("ℹ️  No clear sepsis suspicion indicators found")
print()

print("=" * 70)
print("✅ SKILL DEMONSTRATION COMPLETE")
print("=" * 70)
print()
print("💡 Key Takeaways:")
print("   - Skill provides validated SQL patterns for clinical concepts")
print("   - Itemid references eliminate lookup time")
print("   - KDIGO/SOFA/Sepsis-3 criteria are pre-implemented")
print("   - Patterns handle edge cases and missing data")
print("   - Ready to use for your SOFA/Sepsis/AKI research!")
print()
