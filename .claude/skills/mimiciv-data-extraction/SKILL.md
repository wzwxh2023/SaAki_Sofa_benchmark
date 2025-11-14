# MIMIC-IV Data Extraction Skill

Expert guidance for extracting raw data from MIMIC-IV database, focusing on PostgreSQL queries, table schemas, clinical concepts, and research workflows.

## Overview

MIMIC-IV (Medical Information Mart for Intensive Care IV) is a relational database containing real hospital stays for patients admitted to a tertiary academic medical center in Boston, MA, USA (2008-2019). This skill provides comprehensive guidance for raw data extraction, SQL querying, and clinical concept implementation.

## Database Structure

### Core Modules

MIMIC-IV is organized into five distinct modules:

1. **HOSP** (Hospital): Hospital-wide EHR data including demographics, labs, medications, and billing
2. **ICU** (Intensive Care): ICU event data from MetaVision system
3. **ED** (Emergency Department): Emergency department visits and triage data
4. **CXR** (Chest X-Ray): Chest X-ray metadata linking to MIMIC-CXR
5. **NOTE** (Clinical Notes): Deidentified clinical notes (restricted access)

### Key Schemas

```
mimiciv_hosp    - Hospital data
mimiciv_icu     - ICU event data
mimiciv_ed      - Emergency department data
mimiciv_cxr     - Chest X-ray metadata
```

## Essential Tables for Data Extraction

### Hospital Module (mimiciv_hosp)

#### Core Patient Tables

**patients** - Patient demographics and death information
```sql
-- Columns: subject_id, gender, anchor_age, anchor_year, anchor_year_group, dod
-- Primary Key: subject_id
SELECT * FROM mimiciv_hosp.patients LIMIT 10;
```

**admissions** - Hospital admission details
```sql
-- Columns: subject_id, hadm_id, admittime, dischtime, deathtime, admission_type,
--          admission_location, discharge_location, insurance, language, marital_status, race
-- Primary Key: hadm_id
-- Foreign Key: subject_id → patients.subject_id
SELECT * FROM mimiciv_hosp.admissions LIMIT 10;
```

**transfers** - Patient location transfers within hospital
```sql
-- Columns: subject_id, hadm_id, transfer_id, eventtype, careunit, intime, outtime
-- Primary Key: transfer_id
-- Tracks patient movements between departments/units
SELECT * FROM mimiciv_hosp.transfers LIMIT 10;
```

#### Laboratory Data

**labevents** - All laboratory measurements
```sql
-- Columns: labevent_id, subject_id, hadm_id, specimen_id, itemid, charttime,
--          storetime, value, valuenum, valueuom, ref_range_lower, ref_range_upper, flag, priority, comments
-- Primary Key: labevent_id
-- Foreign Keys: itemid → d_labitems.itemid
-- MASSIVE TABLE: Use proper filtering!

-- Example: Get all creatinine values for a patient
SELECT le.charttime, le.valuenum, le.valueuom, di.label
FROM mimiciv_hosp.labevents le
JOIN mimiciv_hosp.d_labitems di ON le.itemid = di.itemid
WHERE le.subject_id = 10000032
  AND di.label ILIKE '%creatinine%'
ORDER BY le.charttime;
```

**d_labitems** - Laboratory item dictionary
```sql
-- Columns: itemid, label, fluid, category
-- Primary Key: itemid
-- Use to lookup lab test names

-- Common lab itemids:
-- 50912: Creatinine
-- 51222: Hemoglobin
-- 51265: Platelet Count
-- 51301: White Blood Cells
-- 50971: Potassium
-- 50983: Sodium
SELECT * FROM mimiciv_hosp.d_labitems WHERE label ILIKE '%creatinine%';
```

#### Medication Data

**prescriptions** - Prescribed medications
```sql
-- Columns: subject_id, hadm_id, pharmacy_id, starttime, stoptime, drug_type, drug,
--          gsn, ndc, dose_val_rx, dose_unit_rx, form_val_disp, form_unit_disp, route
-- Primary Key: pharmacy_id

-- Example: Get all antibiotics for a patient
SELECT drug, starttime, stoptime, dose_val_rx, dose_unit_rx, route
FROM mimiciv_hosp.prescriptions
WHERE subject_id = 10000032
  AND drug ILIKE '%cipro%' OR drug ILIKE '%vancomycin%';
```

**emar** - Electronic Medication Administration Record
```sql
-- Columns: subject_id, hadm_id, emar_id, emar_seq, poe_id, pharmacy_id,
--          charttime, medication, event_txt, scheduletime, storetime
-- Tracks actual medication administration (vs. prescriptions)
```

#### Diagnosis and Procedure Codes

**diagnoses_icd** - ICD diagnosis codes
```sql
-- Columns: subject_id, hadm_id, seq_num, icd_code, icd_version
-- Foreign Key: icd_code, icd_version → d_icd_diagnoses

-- Example: Find all sepsis diagnoses (ICD-10: A41.*)
SELECT d.subject_id, d.hadm_id, di.long_title, d.seq_num
FROM mimiciv_hosp.diagnoses_icd d
JOIN mimiciv_hosp.d_icd_diagnoses di ON d.icd_code = di.icd_code AND d.icd_version = di.icd_version
WHERE d.icd_code LIKE 'A41%'
  AND d.icd_version = 10;
```

**procedures_icd** - ICD procedure codes
```sql
-- Columns: subject_id, hadm_id, seq_num, chartdate, icd_code, icd_version
-- Billed procedures during hospitalization
```

**d_icd_diagnoses** / **d_icd_procedures** - ICD code dictionaries
```sql
-- Look up ICD code meanings
SELECT icd_code, icd_version, long_title
FROM mimiciv_hosp.d_icd_diagnoses
WHERE long_title ILIKE '%sepsis%';
```

#### Microbiology

**microbiologyevents** - Microbiology culture results
```sql
-- Columns: microevent_id, subject_id, hadm_id, micro_specimen_id, chartdate, charttime,
--          spec_itemid, spec_type_desc, test_itemid, test_name, org_itemid, org_name,
--          isolate_num, quantity, ab_itemid, ab_name, dilution_text, dilution_comparison, dilution_value, interpretation
-- Culture and antibiotic susceptibility results
```

### ICU Module (mimiciv_icu)

#### Core ICU Tables

**icustays** - ICU stay information
```sql
-- Columns: subject_id, hadm_id, stay_id, first_careunit, last_careunit, intime, outtime, los
-- Primary Key: stay_id
-- Central table linking all ICU events

SELECT * FROM mimiciv_icu.icustays LIMIT 10;
```

**d_items** - ICU item dictionary
```sql
-- Columns: itemid, label, abbreviation, linksto, category, unitname, param_type, lownormalvalue, highnormalvalue
-- Primary Key: itemid
-- Defines all concepts recorded in ICU events tables

-- Find vital sign itemids
SELECT * FROM mimiciv_icu.d_items WHERE category = 'Vital Signs';

-- Common itemids:
-- 220045: Heart Rate
-- 220210: Respiratory Rate
-- 220277: O2 saturation pulseoxymetry
-- 220179: Non Invasive Blood Pressure systolic
-- 220180: Non Invasive Blood Pressure diastolic
-- 220181: Non Invasive Blood Pressure mean
-- 223761: Temperature Fahrenheit
```

#### ICU Events Tables (Star Schema)

All ICU events tables share common structure:
- `stay_id`: Links to ICU stay
- `itemid`: Links to d_items for concept definition
- `charttime` or `starttime/endtime`: Event timing

**chartevents** - Charted observations and vital signs
```sql
-- Columns: subject_id, hadm_id, stay_id, charttime, storetime, itemid, value, valuenum, valueuom, warning
-- LARGEST TABLE in MIMIC-IV: Use proper filtering!

-- Example: Get heart rate for an ICU stay
SELECT ce.charttime, ce.valuenum, ce.valueuom, di.label
FROM mimiciv_icu.chartevents ce
JOIN mimiciv_icu.d_items di ON ce.itemid = di.itemid
WHERE ce.stay_id = 30000001
  AND ce.itemid = 220045  -- Heart Rate
  AND ce.valuenum IS NOT NULL
ORDER BY ce.charttime;

-- Example: Get all vital signs for first 24 hours of ICU stay
SELECT
    di.label,
    ce.charttime,
    ce.valuenum,
    ce.valueuom
FROM mimiciv_icu.chartevents ce
JOIN mimiciv_icu.d_items di ON ce.itemid = di.itemid
JOIN mimiciv_icu.icustays ie ON ce.stay_id = ie.stay_id
WHERE ce.stay_id = 30000001
  AND ce.itemid IN (220045, 220210, 220277, 220179, 220180, 223761)  -- Common vitals
  AND ce.charttime BETWEEN ie.intime AND ie.intime + INTERVAL '24 hours'
ORDER BY ce.charttime, di.label;
```

**inputevents** - IV medications, fluids, and nutrition
```sql
-- Columns: subject_id, hadm_id, stay_id, starttime, endtime, storetime, itemid, amount, amountuom,
--          rate, rateuom, ordercategoryname, secondaryordercategoryname, ordercomponenttypedescription,
--          ordercategorydescription, patientweight, totalamount, totalamountuom, isopenbag, continueinnextdept, statusdescription
-- Tracks continuous infusions and intermittent administrations

-- Example: Get vasopressor administration
SELECT
    ie.starttime,
    ie.endtime,
    di.label,
    ie.rate,
    ie.rateuom,
    ie.amount,
    ie.amountuom
FROM mimiciv_icu.inputevents ie
JOIN mimiciv_icu.d_items di ON ie.itemid = di.itemid
WHERE ie.stay_id = 30000001
  AND di.label ILIKE '%norepinephrine%'
ORDER BY ie.starttime;
```

**outputevents** - Patient outputs (urine, drainage, etc.)
```sql
-- Columns: subject_id, hadm_id, stay_id, charttime, storetime, itemid, value, valueuom
-- Tracks urine output, drain output, etc.

-- Example: Calculate hourly urine output
SELECT
    DATE_TRUNC('hour', oe.charttime) as hour,
    SUM(oe.value) as total_urine_ml
FROM mimiciv_icu.outputevents oe
JOIN mimiciv_icu.d_items di ON oe.itemid = di.itemid
WHERE oe.stay_id = 30000001
  AND di.label ILIKE '%urine%'
GROUP BY DATE_TRUNC('hour', oe.charttime)
ORDER BY hour;
```

**procedureevents** - Procedures performed (ventilation, dialysis, etc.)
```sql
-- Columns: subject_id, hadm_id, stay_id, starttime, endtime, storetime, itemid, value, valueuom,
--          location, locationcategory, orderid, linkorderid, ordercategoryname, ordercategorydescription,
--          patientweight, isopenbag, continueinnextdept, statusdescription
-- Documents ICU procedures including ventilation
```

**datetimeevents** - Date/time formatted events
```sql
-- Columns: subject_id, hadm_id, stay_id, charttime, storetime, itemid, value, valueuom, warning
-- Events documented as dates (e.g., date of last dialysis)
```

**ingredientevents** - Medication ingredients
```sql
-- Columns: subject_id, hadm_id, stay_id, starttime, endtime, storetime, itemid, amount, amountuom,
--          rate, rateuom, orderid, linkorderid, statusdescription
-- Tracks ingredients of continuous infusions including nutritional content
```

## Common Data Extraction Patterns

### Patient Cohort Selection

```sql
-- Select adult ICU patients with minimum stay duration
SELECT
    ie.subject_id,
    ie.hadm_id,
    ie.stay_id,
    ie.intime,
    ie.outtime,
    ie.los as length_of_stay_days,
    p.gender,
    p.anchor_age,
    a.admission_type,
    a.hospital_expire_flag
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_hosp.patients p ON ie.subject_id = p.subject_id
INNER JOIN mimiciv_hosp.admissions a ON ie.hadm_id = a.hadm_id
WHERE p.anchor_age >= 18  -- Adult patients
  AND ie.los >= 1  -- Minimum 1 day stay
ORDER BY ie.stay_id;
```

### Time-Series Data Extraction

```sql
-- Extract vital signs time series for ICU stay
WITH vital_signs AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        MAX(CASE WHEN ce.itemid = 220045 THEN ce.valuenum END) as heart_rate,
        MAX(CASE WHEN ce.itemid = 220210 THEN ce.valuenum END) as resp_rate,
        MAX(CASE WHEN ce.itemid = 220277 THEN ce.valuenum END) as spo2,
        MAX(CASE WHEN ce.itemid = 220179 THEN ce.valuenum END) as sbp,
        MAX(CASE WHEN ce.itemid = 220180 THEN ce.valuenum END) as dbp,
        MAX(CASE WHEN ce.itemid = 220181 THEN ce.valuenum END) as mbp,
        MAX(CASE WHEN ce.itemid IN (223761, 223762) THEN ce.valuenum END) as temperature
    FROM mimiciv_icu.chartevents ce
    WHERE ce.stay_id = 30000001
      AND ce.itemid IN (220045, 220210, 220277, 220179, 220180, 220181, 223761, 223762)
    GROUP BY ce.stay_id, ce.charttime
)
SELECT * FROM vital_signs ORDER BY charttime;
```

### Laboratory Data with Reference Ranges

```sql
-- Get lab values with abnormality flags
SELECT
    le.subject_id,
    le.hadm_id,
    le.charttime,
    di.label as lab_name,
    le.valuenum as value,
    le.valueuom as unit,
    le.ref_range_lower,
    le.ref_range_upper,
    le.flag,
    CASE
        WHEN le.valuenum < le.ref_range_lower THEN 'Low'
        WHEN le.valuenum > le.ref_range_upper THEN 'High'
        ELSE 'Normal'
    END as interpretation
FROM mimiciv_hosp.labevents le
JOIN mimiciv_hosp.d_labitems di ON le.itemid = di.itemid
WHERE le.hadm_id = 20000001
  AND di.label IN ('Creatinine', 'Hemoglobin', 'Platelet Count', 'White Blood Cells')
  AND le.valuenum IS NOT NULL
ORDER BY di.label, le.charttime;
```

### Medication Exposure Windows

```sql
-- Calculate medication exposure periods
SELECT
    p.subject_id,
    p.hadm_id,
    p.drug,
    p.starttime,
    p.stoptime,
    p.stoptime - p.starttime as duration,
    p.dose_val_rx,
    p.dose_unit_rx,
    p.route
FROM mimiciv_hosp.prescriptions p
WHERE p.hadm_id = 20000001
  AND p.drug ILIKE '%vancomycin%'
ORDER BY p.starttime;
```

## Clinical Concepts and Derived Variables

MIMIC-IV provides pre-computed clinical concepts in the `mimic_derived` dataset (BigQuery) or via SQL scripts in the [mimic-code repository](https://github.com/MIT-LCP/mimic-code/tree/main/mimic-iv/concepts).

### SOFA Score (Sequential Organ Failure Assessment)

**Location**: `concepts/score/sofa.sql`

SOFA score components:
1. **Respiration**: PaO2/FiO2 ratio
2. **Coagulation**: Platelets
3. **Liver**: Bilirubin
4. **Cardiovascular**: Mean arterial pressure and vasopressor use
5. **CNS**: Glasgow Coma Scale
6. **Renal**: Creatinine and urine output

```sql
-- First day SOFA score (pre-computed concept)
-- Available in mimic_derived.first_day_sofa

-- Manual SOFA calculation example for respiration component:
WITH pao2_fio2 AS (
    SELECT
        stay_id,
        charttime,
        -- PaO2 from blood gas
        MAX(CASE WHEN itemid = 50821 THEN valuenum END) as pao2,
        -- FiO2
        MAX(CASE WHEN itemid IN (223835, 50816) THEN valuenum END) as fio2
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (50821, 223835, 50816)
    GROUP BY stay_id, charttime
)
SELECT
    stay_id,
    pao2,
    fio2,
    pao2/fio2 as pf_ratio,
    CASE
        WHEN pao2/fio2 < 100 THEN 4
        WHEN pao2/fio2 < 200 THEN 3
        WHEN pao2/fio2 < 300 THEN 2
        WHEN pao2/fio2 < 400 THEN 1
        ELSE 0
    END as sofa_respiration
FROM pao2_fio2
WHERE pao2 IS NOT NULL AND fio2 IS NOT NULL;
```

**Key SOFA-related itemids**:
- Platelets: 51265 (lab)
- Bilirubin: 50885 (lab)
- Creatinine: 50912 (lab)
- GCS: 220739 (total), 223900 (verbal), 223901 (motor), 220739 (eye)
- MAP: 220052, 220181
- Vasopressors: See medication concepts

### Sepsis-3 Criteria

**Location**: `concepts/sepsis/sepsis3.sql`

Sepsis-3 definition requires:
1. **Suspected infection**: Antibiotics + culture within specific time window
2. **Organ dysfunction**: SOFA score ≥ 2 points increase from baseline

```sql
-- Simplified sepsis suspicion detection
WITH antibiotics AS (
    SELECT DISTINCT
        subject_id,
        hadm_id,
        starttime as antibiotic_time
    FROM mimiciv_hosp.prescriptions
    WHERE drug IN (
        -- Common antibiotics
        'Vancomycin', 'Piperacillin-Tazobactam', 'Cefepime',
        'Meropenem', 'Levofloxacin', 'Ciprofloxacin'
    )
),
cultures AS (
    SELECT DISTINCT
        subject_id,
        hadm_id,
        charttime as culture_time
    FROM mimiciv_hosp.microbiologyevents
    WHERE spec_type_desc IN ('BLOOD CULTURE', 'URINE', 'SPUTUM')
)
SELECT
    a.subject_id,
    a.hadm_id,
    a.antibiotic_time,
    c.culture_time,
    ABS(EXTRACT(EPOCH FROM (a.antibiotic_time - c.culture_time))/3600) as hours_between
FROM antibiotics a
INNER JOIN cultures c
    ON a.subject_id = c.subject_id
    AND a.hadm_id = c.hadm_id
WHERE ABS(EXTRACT(EPOCH FROM (a.antibiotic_time - c.culture_time))/3600) <= 24
ORDER BY a.subject_id, a.antibiotic_time;
```

### Acute Kidney Injury (AKI) - KDIGO Criteria

**Location**: `concepts/organfailure/kdigo_creatinine.sql` and `kdigo_uo.sql`

KDIGO stages based on:
1. **Creatinine criteria**: Increase from baseline
2. **Urine output criteria**: < 0.5 mL/kg/hr for 6-12 hours

```sql
-- AKI detection using creatinine (simplified)
WITH baseline_cr AS (
    SELECT
        le.subject_id,
        le.hadm_id,
        MIN(le.valuenum) as baseline_creatinine
    FROM mimiciv_hosp.labevents le
    JOIN mimiciv_hosp.d_labitems di ON le.itemid = di.itemid
    WHERE di.label = 'Creatinine'
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
    WHERE di.label = 'Creatinine'
      AND le.valuenum IS NOT NULL
)
SELECT
    c.subject_id,
    c.hadm_id,
    c.charttime,
    b.baseline_creatinine,
    c.creatinine as current_creatinine,
    c.creatinine - b.baseline_creatinine as cr_increase,
    CASE
        WHEN c.creatinine >= b.baseline_creatinine * 3 THEN 'Stage 3'
        WHEN c.creatinine >= b.baseline_creatinine * 2 THEN 'Stage 2'
        WHEN c.creatinine >= b.baseline_creatinine + 0.3
             OR c.creatinine >= b.baseline_creatinine * 1.5 THEN 'Stage 1'
        ELSE 'No AKI'
    END as aki_stage
FROM current_cr c
LEFT JOIN baseline_cr b ON c.subject_id = b.subject_id AND c.hadm_id = b.hadm_id
WHERE b.baseline_creatinine IS NOT NULL;
```

### Mechanical Ventilation

**Location**: `concepts/treatment/ventilation.sql`

Detection strategies:
1. Ventilator settings in chartevents
2. Procedure events for intubation
3. Oxygen delivery methods

```sql
-- Detect ventilation periods
SELECT
    ce.stay_id,
    ce.charttime,
    di.label,
    ce.value
FROM mimiciv_icu.chartevents ce
JOIN mimiciv_icu.d_items di ON ce.itemid = di.itemid
WHERE ce.stay_id = 30000001
  AND di.label ILIKE '%ventilator%'
  OR di.label ILIKE '%peep%'
  OR di.label ILIKE '%fio2%'
ORDER BY ce.charttime;
```

### First Day Measurements

**Location**: `concepts/first_day/`

Common first-day extractions:
- `first_day_sofa.sql`: SOFA score within first 24 hours
- `first_day_vitalsign.sql`: Vital sign summary (min, max, mean)
- `first_day_lab.sql`: Laboratory values
- `first_day_urine_output.sql`: Total urine output
- `first_day_gcs.sql`: Glasgow Coma Scale

Pattern for first 24-hour aggregation:
```sql
-- First day vital signs summary
SELECT
    ie.stay_id,
    -- Heart rate statistics
    MIN(CASE WHEN ce.itemid = 220045 THEN ce.valuenum END) as hr_min,
    MAX(CASE WHEN ce.itemid = 220045 THEN ce.valuenum END) as hr_max,
    AVG(CASE WHEN ce.itemid = 220045 THEN ce.valuenum END) as hr_mean,
    -- Blood pressure statistics
    MIN(CASE WHEN ce.itemid = 220181 THEN ce.valuenum END) as mbp_min,
    MAX(CASE WHEN ce.itemid = 220181 THEN ce.valuenum END) as mbp_max,
    AVG(CASE WHEN ce.itemid = 220181 THEN ce.valuenum END) as mbp_mean
FROM mimiciv_icu.icustays ie
LEFT JOIN mimiciv_icu.chartevents ce
    ON ie.stay_id = ce.stay_id
    AND ce.charttime BETWEEN ie.intime AND ie.intime + INTERVAL '24 hours'
    AND ce.itemid IN (220045, 220181)  -- HR, MAP
GROUP BY ie.stay_id;
```

## Data Quality Considerations

### Missing Data Handling

```sql
-- Check for missing values
SELECT
    COUNT(*) as total_rows,
    COUNT(valuenum) as non_null_values,
    COUNT(*) - COUNT(valuenum) as null_values,
    ROUND(100.0 * COUNT(valuenum) / COUNT(*), 2) as completeness_pct
FROM mimiciv_hosp.labevents
WHERE itemid = 50912;  -- Creatinine
```

### Outlier Detection

```sql
-- Identify potential outliers using IQR method
WITH stats AS (
    SELECT
        itemid,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY valuenum) as q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY valuenum) as q3
    FROM mimiciv_hosp.labevents
    WHERE itemid = 50912
      AND valuenum IS NOT NULL
    GROUP BY itemid
)
SELECT
    le.*,
    CASE
        WHEN le.valuenum < (s.q1 - 1.5 * (s.q3 - s.q1)) THEN 'Low Outlier'
        WHEN le.valuenum > (s.q3 + 1.5 * (s.q3 - s.q1)) THEN 'High Outlier'
        ELSE 'Normal Range'
    END as outlier_status
FROM mimiciv_hosp.labevents le
JOIN stats s ON le.itemid = s.itemid
WHERE le.itemid = 50912;
```

### Duplicate Record Handling

```sql
-- Identify duplicate chartevents
SELECT
    subject_id,
    hadm_id,
    stay_id,
    charttime,
    itemid,
    COUNT(*) as duplicate_count
FROM mimiciv_icu.chartevents
WHERE stay_id = 30000001
GROUP BY subject_id, hadm_id, stay_id, charttime, itemid
HAVING COUNT(*) > 1;
```

## Performance Optimization

### Indexing Strategy

Common beneficial indexes:
```sql
-- Time-based queries
CREATE INDEX idx_chartevents_charttime ON mimiciv_icu.chartevents(charttime);
CREATE INDEX idx_labevents_charttime ON mimiciv_hosp.labevents(charttime);

-- Patient/admission filtering
CREATE INDEX idx_chartevents_stay_id ON mimiciv_icu.chartevents(stay_id);
CREATE INDEX idx_labevents_hadm_id ON mimiciv_hosp.labevents(hadm_id);

-- Item filtering
CREATE INDEX idx_chartevents_itemid ON mimiciv_icu.chartevents(itemid);
CREATE INDEX idx_labevents_itemid ON mimiciv_hosp.labevents(itemid);
```

### Query Optimization Tips

1. **Always filter by patient/admission/stay first**
```sql
-- Good: Filter by stay_id first
WHERE stay_id IN (SELECT stay_id FROM my_cohort)
  AND itemid = 220045

-- Bad: Filter by itemid across entire table
WHERE itemid = 220045
```

2. **Use appropriate time windows**
```sql
-- Limit time range for large tables
WHERE charttime BETWEEN '2015-01-01' AND '2015-12-31'
```

3. **Limit itemids for chartevents/labevents**
```sql
-- Only query needed items
WHERE itemid IN (220045, 220210, 220277)  -- Specific vital signs
```

4. **Use CTEs for complex queries**
```sql
-- Break complex queries into readable CTEs
WITH cohort AS (...),
     vitals AS (...),
     labs AS (...)
SELECT * FROM cohort
JOIN vitals USING (stay_id)
JOIN labs USING (stay_id);
```

## Common Research Use Cases

### Sepsis Cohort with Outcomes

```sql
-- Build sepsis cohort with demographics and outcomes
WITH sepsis_patients AS (
    -- Use derived sepsis table or custom definition
    SELECT DISTINCT subject_id, hadm_id, stay_id
    FROM mimiciv_derived.sepsis3
    WHERE sepsis3 = True
)
SELECT
    sp.subject_id,
    sp.hadm_id,
    sp.stay_id,
    p.gender,
    p.anchor_age as age,
    ie.intime,
    ie.outtime,
    ie.los,
    a.hospital_expire_flag,
    a.admission_type,
    a.race,
    a.insurance
FROM sepsis_patients sp
JOIN mimiciv_hosp.patients p ON sp.subject_id = p.subject_id
JOIN mimiciv_icu.icustays ie ON sp.stay_id = ie.stay_id
JOIN mimiciv_hosp.admissions a ON sp.hadm_id = a.hadm_id;
```

### Longitudinal Vital Signs

```sql
-- Extract vital signs trajectory for cohort
SELECT
    ce.stay_id,
    ce.charttime,
    EXTRACT(EPOCH FROM (ce.charttime - ie.intime))/3600 as hours_since_admission,
    di.label as vital_sign,
    ce.valuenum as value,
    ce.valueuom as unit
FROM my_cohort mc
JOIN mimiciv_icu.icustays ie ON mc.stay_id = ie.stay_id
JOIN mimiciv_icu.chartevents ce ON mc.stay_id = ce.stay_id
JOIN mimiciv_icu.d_items di ON ce.itemid = di.itemid
WHERE ce.itemid IN (220045, 220210, 220277, 220181)  -- HR, RR, SpO2, MAP
  AND ce.charttime BETWEEN ie.intime AND ie.outtime
  AND ce.valuenum IS NOT NULL
ORDER BY ce.stay_id, ce.charttime, di.label;
```

### Medication Exposure Analysis

```sql
-- Calculate days of antibiotic therapy
SELECT
    p.subject_id,
    p.hadm_id,
    p.drug,
    COUNT(DISTINCT DATE(e.charttime)) as days_of_therapy,
    MIN(e.charttime) as first_dose,
    MAX(e.charttime) as last_dose
FROM mimiciv_hosp.prescriptions p
JOIN mimiciv_hosp.emar e
    ON p.subject_id = e.subject_id
    AND p.hadm_id = e.hadm_id
    AND p.drug = e.medication
WHERE p.drug IN ('Vancomycin', 'Piperacillin-Tazobactam')
  AND e.event_txt = 'Administered'
GROUP BY p.subject_id, p.hadm_id, p.drug;
```

### Comorbidity Extraction (Charlson Index)

```sql
-- Extract Charlson comorbidities from ICD codes
-- Use pre-computed: mimiciv_derived.charlson

-- Manual extraction example:
SELECT
    d.subject_id,
    d.hadm_id,
    BOOL_OR(d.icd_code LIKE 'I21%') as myocardial_infarction,
    BOOL_OR(d.icd_code LIKE 'I50%') as congestive_heart_failure,
    BOOL_OR(d.icd_code LIKE 'I63%' OR d.icd_code LIKE 'I64%') as cerebrovascular_disease,
    BOOL_OR(d.icd_code LIKE 'J40%' OR d.icd_code LIKE 'J41%' OR d.icd_code LIKE 'J42%' OR d.icd_code LIKE 'J43%' OR d.icd_code LIKE 'J44%') as copd,
    BOOL_OR(d.icd_code LIKE 'N18%') as chronic_kidney_disease,
    BOOL_OR(d.icd_code LIKE 'C%') as cancer
FROM mimiciv_hosp.diagnoses_icd d
WHERE d.icd_version = 10
GROUP BY d.subject_id, d.hadm_id;
```

## Connection and Access

### PostgreSQL Connection (Local/WSL)

```python
import pandas as pd
from sqlalchemy import create_engine

# Connection parameters
config = {
    'host': '172.24.160.1',  # Windows host from WSL
    'port': 5432,
    'database': 'mimiciv',
    'user': 'postgres',
    'password': 'your_password'
}

# Create engine
engine = create_engine(
    f"postgresql://{config['user']}:{config['password']}@"
    f"{config['host']}:{config['port']}/{config['database']}"
)

# Query to DataFrame
sql = "SELECT * FROM mimiciv_icu.icustays LIMIT 10"
df = pd.read_sql(sql, engine)
```

### BigQuery Access (Cloud)

```python
from google.cloud import bigquery

client = bigquery.Client(project='your-project-id')

query = """
SELECT *
FROM `physionet-data.mimiciv_icu.icustays`
LIMIT 10
"""

df = client.query(query).to_dataframe()
```

## Best Practices

### 1. Start Small, Then Scale
```sql
-- Always test queries on small subset first
LIMIT 1000
```

### 2. Use Derived Tables When Available
```python
# Pre-computed concepts save computation time
# Available in mimiciv_derived schema (BigQuery) or via mimic-code SQL scripts
```

### 3. Document Your Cohort Definition
```sql
-- Always clearly define inclusion/exclusion criteria
-- Example:
-- Inclusion:
--   - Age >= 18
--   - ICU stay >= 24 hours
--   - First ICU admission only
-- Exclusion:
--   - Missing key variables (e.g., no creatinine measurements)
```

### 4. Validate Against Known Values
```sql
-- Compare your extractions with published MIMIC-IV statistics
-- Total patients: ~380,000
-- Total admissions: ~520,000
-- Total ICU stays: ~76,000
```

### 5. Handle Time Zones Consistently
```sql
-- All timestamps in MIMIC-IV are in local time (US Eastern)
-- Be consistent with time zone handling in analyses
```

## Common Itemid Reference

### ICU Chartevents

**Vital Signs**
- 220045: Heart Rate
- 220210: Respiratory Rate
- 220277: SpO2 (oxygen saturation)
- 220179: Non-invasive BP systolic
- 220180: Non-invasive BP diastolic
- 220181: Non-invasive BP mean
- 223761: Temperature Fahrenheit
- 223762: Temperature Celsius
- 220052: Arterial BP mean

**Ventilator Settings**
- 224688: Respiratory Rate (Set)
- 224689: Tidal Volume (Set)
- 224690: PEEP Set
- 223835: FiO2

**Urine Output**
- 226559: Foley catheter
- 226560: Void
- 227488: GU Irrigant Volume In
- 227489: GU Irrigant/Urine Volume Out

### Hospital Labevents

**Chemistry**
- 50912: Creatinine
- 50971: Potassium
- 50983: Sodium
- 50902: Chloride
- 50882: Bicarbonate

**Hematology**
- 51222: Hemoglobin
- 51265: Platelet Count
- 51301: White Blood Cells
- 51221: Hematocrit

**Liver Function**
- 50885: Bilirubin, Total
- 50878: AST
- 50861: ALT

**Coagulation**
- 51237: INR
- 51274: PT
- 51275: PTT

**Blood Gas**
- 50821: PaO2
- 50818: PCO2
- 50820: pH
- 50802: Base Excess

## Troubleshooting

### Common Issues

**1. Query Too Slow**
- Add filters for stay_id/hadm_id first
- Limit itemid selection
- Use appropriate time windows
- Consider using derived tables

**2. Unexpected NULL Values**
- Check valuenum vs value (string vs numeric)
- Verify itemid is correct
- Check if data exists for that patient/time period

**3. Duplicate Records**
- chartevents may have duplicates for same charttime
- Use DISTINCT or GROUP BY with aggregation
- Consider ROW_NUMBER() for deduplication

**4. Time Alignment Issues**
- Use appropriate time binning (hourly, daily)
- Handle irregular sampling with LOCF or interpolation
- Be aware of storetime vs charttime differences

## Additional Resources

### Official Documentation
- MIMIC-IV Documentation: https://mimic.mit.edu/docs/iv/
- MIMIC Code Repository: https://github.com/MIT-LCP/mimic-code
- PhysioNet: https://physionet.org/content/mimiciv/

### Key Papers
- Johnson et al. (2023). "MIMIC-IV, a freely accessible electronic health record dataset." Scientific Data.

### Community
- MIMIC User Group: https://groups.google.com/forum/#!forum/mimicdata
- PhysioNet Forums: https://groups.google.com/forum/#!forum/physionet-users

---

**Skill Version**: 1.0
**Created**: 2025
**Focus**: Raw data extraction from MIMIC-IV PostgreSQL database
**Primary Use**: Clinical research, sepsis analysis, organ dysfunction scoring, ICU analytics
