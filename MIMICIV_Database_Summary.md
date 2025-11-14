# MIMIC-IV Database Exploration Summary

**Date**: 2025-11-14
**Database**: mimiciv
**Host**: 172.19.160.1:5432
**Status**: ✅ Connected and Fully Explored

---

## Database Overview

Your MIMIC-IV database contains **3 schemas** with **111 tables** and over **620 million rows** of clinical data.

### Schemas

| Schema | Tables | Description |
|--------|--------|-------------|
| **mimiciv_hosp** | 29 | Hospital-wide EHR data including demographics, labs, medications, diagnoses |
| **mimiciv_icu** | 10 | ICU event data from MetaVision system (vitals, inputs, outputs, procedures) |
| **mimiciv_derived** | 72 | Pre-computed derived tables with clinical concepts (SOFA, Sepsis, AKI, etc.) |

---

## Core Tables (Patient Cohorts)

| Schema | Table | Row Count | Description |
|--------|-------|-----------|-------------|
| mimiciv_hosp | **patients** | **364,627** | Patient demographics and death information |
| mimiciv_hosp | **admissions** | **546,028** | Hospital admission details |
| mimiciv_icu | **icustays** | **94,458** | ICU stay information |

### Key Insights
- Average 1.5 admissions per patient
- 17.3% of admissions involve ICU care
- All tables have proper foreign key relationships

---

## Hospital Data Tables (mimiciv_hosp)

### Laboratory & Medications

| Table | Row Count | Description |
|-------|-----------|-------------|
| **labevents** | **158,478,383** | All laboratory measurements (158 million) |
| **d_labitems** | **1,650** | Laboratory item dictionary (itemid lookup) |
| **prescriptions** | **20,292,611** | Prescribed medications (20 million) |
| **microbiologyevents** | **3,988,224** | Microbiology culture results |

### Diagnoses & Procedures

| Table | Row Count | Description |
|-------|-----------|-------------|
| **diagnoses_icd** | **6,364,520** | ICD-9/ICD-10 diagnosis codes |
| **procedures_icd** | - | ICD procedure codes |
| **d_icd_diagnoses** | - | ICD diagnosis code dictionary |
| **d_icd_procedures** | - | ICD procedure code dictionary |

### Key Laboratory Items (Common itemids)

```sql
-- Creatinine: 50912
-- Platelets: 51265
-- Bilirubin: 50885
-- Hemoglobin: 51222
-- White Blood Cells: 51301
-- Potassium: 50971
-- Sodium: 50983
```

---

## ICU Data Tables (mimiciv_icu)

| Table | Row Count | Description |
|-------|-----------|-------------|
| **chartevents** | **432,997,491** | ICU charted observations (433 million!) |
| **inputevents** | **10,953,713** | IV medications, fluids, nutrition |
| **outputevents** | **5,359,395** | Urine output, drainage |
| **procedureevents** | - | ICU procedures (ventilation, dialysis) |
| **d_items** | **4,095** | ICU item dictionary (itemid lookup) |

### Key ICU Items (Common itemids)

```sql
-- Vital Signs:
--   Heart Rate: 220045
--   Respiratory Rate: 220210
--   SpO2: 220277
--   MAP (non-invasive): 220181
--   Temperature (F): 223761
--   Temperature (C): 223762
--   Systolic BP: 220179
--   Diastolic BP: 220180
```

---

## Derived Tables (mimiciv_derived) - **PRE-COMPUTED CONCEPTS**

### ⭐ Clinical Scores

| Table | Row Count | Description |
|-------|-----------|-------------|
| **sofa** | **8,219,121** | Sequential Organ Failure Assessment (time-series) |
| **first_day_sofa** | **94,458** | First 24h SOFA scores (one per ICU stay) |
| **apsiii** | - | APACHE III severity scores |
| **sapsii** | - | SAPS II severity scores |
| **oasis** | - | OASIS severity scores |
| **lods** | - | Logistic Organ Dysfunction scores |
| **sirs** | - | SIRS criteria |

### 🦠 Sepsis & Infection

| Table | Row Count | Description |
|-------|-----------|-------------|
| **sepsis3** | **41,295** | Sepsis-3 positive cases |
| **sepsis3_detail** | - | Detailed sepsis information |
| **suspicion_of_infection** | - | Antibiotic + culture timing |

### 🫘 Acute Kidney Injury (AKI)

| Table | Row Count | Description |
|-------|-----------|-------------|
| **kdigo_stages** | **5,099,899** | KDIGO AKI staging (time-series) |
| **kdigo_creatinine** | - | AKI based on creatinine criteria |
| **kdigo_uo** | - | AKI based on urine output criteria |
| **creatinine_baseline** | - | Baseline creatinine calculations |

### 💊 Medications

| Table | Description |
|-------|-------------|
| **norepinephrine** | Norepinephrine administration |
| **epinephrine** | Epinephrine administration |
| **dopamine** | Dopamine administration |
| **dobutamine** | Dobutamine administration |
| **vasopressin** | Vasopressin administration |
| **phenylephrine** | Phenylephrine administration |
| **vasoactive_agent** | All vasoactive agents combined |

### 📊 First Day Measurements

| Table | Row Count | Description |
|-------|-----------|-------------|
| **first_day_lab** | **94,458** | First 24h laboratory values |
| **first_day_vitalsign** | - | First 24h vital signs summary |
| **first_day_urine_output** | - | First 24h urine output |
| **first_day_gcs** | - | First 24h Glasgow Coma Scale |
| **first_day_bg** | - | First 24h blood gas |
| **first_day_height** | - | Patient height |
| **first_day_weight** | - | Patient weight |

### 🫁 Ventilation & Support

| Table | Description |
|-------|-------------|
| **ventilation** | Mechanical ventilation periods |
| **ventilator_setting** | Ventilator parameters |
| **rrt** | Renal replacement therapy |
| **crrt** | Continuous RRT |

### 🧪 Laboratory Panels

| Table | Description |
|-------|-------------|
| **chemistry** | Chemistry panel |
| **complete_blood_count** | CBC panel |
| **blood_differential** | Blood differential |
| **coagulation** | Coagulation studies |
| **cardiac_marker** | Cardiac markers |
| **inflammation** | Inflammatory markers |
| **bg** | Blood gas measurements |

---

## Table Relationships

### Primary Foreign Keys

```
mimiciv_hosp.patients.subject_id  (PRIMARY KEY)
    ↓
mimiciv_hosp.admissions (subject_id, hadm_id)
    ↓
mimiciv_icu.icustays (subject_id, hadm_id, stay_id)
    ↓
mimiciv_icu.chartevents (subject_id, hadm_id, stay_id, itemid)
mimiciv_icu.inputevents (subject_id, hadm_id, stay_id, itemid)
mimiciv_icu.outputevents (subject_id, hadm_id, stay_id, itemid)

mimiciv_hosp.labevents (subject_id, hadm_id, itemid)
mimiciv_hosp.prescriptions (subject_id, hadm_id)
```

### Dictionary Tables (Lookup)

```
mimiciv_icu.d_items.itemid → ICU item definitions
mimiciv_hosp.d_labitems.itemid → Lab test definitions
mimiciv_hosp.d_icd_diagnoses → ICD diagnosis codes
mimiciv_hosp.d_icd_procedures → ICD procedure codes
```

---

## Database Size Summary

### Largest Tables by Row Count

| Rank | Table | Rows | Size |
|------|-------|------|------|
| 1 | **mimiciv_icu.chartevents** | 432,997,491 | 42 GB |
| 2 | **mimiciv_hosp.labevents** | 158,478,383 | 25 GB |
| 3 | **mimiciv_hosp.prescriptions** | 20,292,611 | 4.7 GB |
| 4 | **mimiciv_icu.inputevents** | 10,953,713 | 3.1 GB |
| 5 | **mimiciv_derived.sofa** | 8,219,121 | 943 MB |
| 6 | **mimiciv_hosp.diagnoses_icd** | 6,364,520 | 563 MB |
| 7 | **mimiciv_icu.outputevents** | 5,359,395 | 792 MB |
| 8 | **mimiciv_derived.kdigo_stages** | 5,099,899 | 448 MB |
| 9 | **mimiciv_hosp.microbiologyevents** | 3,988,224 | 1.1 GB |
| 10 | **mimiciv_derived.sepsis3** | 41,295 | 4.1 MB |

### Total Estimated Size: **~80 GB**

---

## Pre-Computed Tables Available

✅ **You have access to pre-computed derived tables!**

This means you **don't need to calculate** these from scratch:
- ✅ SOFA scores (complete time-series + first day)
- ✅ Sepsis-3 cases (already identified)
- ✅ KDIGO AKI stages (creatinine + urine output)
- ✅ First day vital signs, labs, GCS
- ✅ Vasopressor administration records
- ✅ Mechanical ventilation periods
- ✅ Charlson comorbidity index

---

## Quick Start Queries

### Example 1: Get Sepsis Patients with SOFA Scores

```sql
SELECT
    s.subject_id,
    s.hadm_id,
    s.stay_id,
    s.sepsis3,
    s.sofa_24hours,
    fs.respiration_24hours,
    fs.coagulation_24hours,
    fs.liver_24hours,
    fs.cardiovascular_24hours,
    fs.cns_24hours,
    fs.renal_24hours
FROM mimiciv_derived.sepsis3 s
JOIN mimiciv_derived.first_day_sofa fs ON s.stay_id = fs.stay_id
WHERE s.sepsis3 = true
LIMIT 100;
```

### Example 2: Get AKI Patients

```sql
SELECT
    k.subject_id,
    k.hadm_id,
    k.stay_id,
    k.aki_stage,
    k.creatinine,
    k.uo_24hr
FROM mimiciv_derived.kdigo_stages k
WHERE k.aki_stage >= 1
LIMIT 100;
```

### Example 3: Get Vital Signs for ICU Stay

```sql
SELECT
    v.stay_id,
    v.charttime,
    v.heart_rate,
    v.sbp,
    v.dbp,
    v.mbp,
    v.resp_rate,
    v.temperature,
    v.spo2
FROM mimiciv_derived.vitalsign v
WHERE v.stay_id = 30000001
ORDER BY v.charttime
LIMIT 100;
```

---

## Using the MIMIC-IV Skill

The MIMIC-IV Data Extraction Skill (located at `.claude/skills/mimiciv-data-extraction/`) provides:

1. **Complete Table Documentation** - All schemas, columns, relationships
2. **ItemID Reference Guide** - Quick lookup for vital signs, labs, medications
3. **SQL Query Patterns** - Validated queries for common tasks
4. **Clinical Concept Implementations** - SOFA, Sepsis, AKI from raw data
5. **Performance Optimization Tips** - How to query large tables efficiently

### Accessing the Skill

Reference the skill when working with MIMIC-IV:
```
"Using the MIMIC-IV skill, help me extract first-day SOFA scores for sepsis patients"
```

Or review the skill documentation directly:
```bash
cat .claude/skills/mimiciv-data-extraction/SKILL.md
```

---

## Next Steps for Your Research

### For SOFA/Sepsis/AKI Analysis:

1. **✅ Database is ready** - All tables populated and accessible
2. **✅ Derived tables available** - SOFA, Sepsis3, KDIGO already computed
3. **✅ Connection configured** - db_helper.py ready to use

### Recommended Workflow:

```python
from utils.db_helper import query_to_df

# Option 1: Use pre-computed tables (FAST)
sofa_df = query_to_df("""
    SELECT * FROM mimiciv_derived.first_day_sofa
    WHERE sofa_24hours >= 2
""", db='mimic')

# Option 2: Build custom cohort from raw data
cohort_df = query_to_df("""
    SELECT
        ie.stay_id,
        p.anchor_age,
        ie.los,
        a.hospital_expire_flag
    FROM mimiciv_icu.icustays ie
    JOIN mimiciv_hosp.patients p ON ie.subject_id = p.subject_id
    JOIN mimiciv_hosp.admissions a ON ie.hadm_id = a.hadm_id
    WHERE p.anchor_age >= 18 AND ie.los >= 1
""", db='mimic')
```

---

## Summary

🎉 **Your MIMIC-IV database is fully operational!**

- **364,627** patients
- **546,028** hospital admissions
- **94,458** ICU stays
- **41,295** sepsis cases (pre-identified)
- **Over 620 million** clinical events

You have **everything needed** for SOFA/Sepsis/AKI research including:
- ✅ Raw data tables (hosp, icu)
- ✅ Pre-computed clinical concepts (derived)
- ✅ Database connection configured
- ✅ MIMIC-IV skill for query patterns
- ✅ Helper functions for data extraction

**Ready to start your analysis!** 🚀
