# Patient Outcomes Complete Data Dictionary

## Overview
Complete patient outcomes dataset from MIMIC-IV containing 94,458 ICU stays with comprehensive SOFA and SOFA2 scores, mortality outcomes, ventilation, renal replacement therapy, and survival metrics.

## Key Statistics
- **Total ICU stays**: 94,458
- **Patients with RRT**: 6,111 (6.5%)
- **Patients with invasive ventilation**: 34,837 (36.9%)
- **Patients with both SOFA and SOFA2 scores**: 89,108 (94.4%)

## Field Descriptions

### Basic Identifiers
- **subject_id**: Unique patient identifier
- **hadm_id**: Hospital admission identifier
- **stay_id**: ICU stay identifier

### Demographics
- **gender**: Patient gender (M/F)
- **anchor_age**: Patient age at hospital admission
- **race**: Patient race/ethnicity
- **insurance**: Primary insurance type
- **admission_type**: Type of hospital admission
- **admission_location**: Where patient was admitted from

### ICU and Hospital Information
- **first_careunit**: First ICU unit type
- **last_careunit**: Last ICU unit type
- **icu_intime**: ICU admission timestamp
- **icu_outtime**: ICU discharge timestamp
- **icu_los**: ICU length of stay (days)
- **hospital_los**: Hospital length of stay (days)
- **discharge_location**: Discharge destination

### Mortality Outcomes
- **hospital_mortality**: In-hospital death (1=Yes, 0=No)
- **icu_mortality**: ICU death (1=Yes, 0=No)
- **death_location**: Location of death (In-hospital, Post-discharge, Alive)

### Survival Times (in days)
- **icu_survival_days**: Days from ICU admission to death/discharge
- **overall_survival_days**: Days from hospital admission to death/discharge
- **pre_icu_hospital_days**: Days from hospital admission to ICU admission

### Mortality Time Windows
- **icu_death_within_28_days**: Death within 28 days of ICU admission
- **icu_death_within_90_days**: Death within 90 days of ICU admission

### SOFA Scores (Sequential Organ Failure Assessment)
- **sofa_score**: Total SOFA score (0-24)
- **sofa_respiration**: Respiratory component (0-4)
- **sofa_coagulation**: Coagulation component (0-4)
- **sofa_liver**: Liver component (0-4)
- **sofa_cardiovascular**: Cardiovascular component (0-4)
- **sofa_cns**: Central nervous system component (0-4)
- **sofa_renal**: Renal component (0-4)

### SOFA2 Scores (Updated SOFA)
- **sofa2_score**: Total SOFA2 score (0-28)
- **sofa2_respiratory**: Respiratory component (0-4)
- **sofa2_hemostasis**: Hemostasis component (0-4)
- **sofa2_liver**: Liver component (0-4)
- **sofa2_cardiovascular**: Cardiovascular component (0-4)
- **sofa2_brain**: Brain component (0-4)
- **sofa2_kidney**: Kidney component (0-4)

### Sepsis Diagnosis
- **sepsis3_sofa**: Sepsis-3 based on SOFA score (1=Yes, 0=No)
- **sepsis3_sofa2**: Sepsis-3 based on SOFA2 score (1=Yes, 0=No)

### Ventilation Outcomes
- **invasive_ventilation**: Received invasive mechanical ventilation (1=Yes, 0=No)
- **tracheostomy**: Had tracheostomy (1=Yes, 0=No)
- **invasive_vent_sessions**: Number of invasive ventilation sessions
- **total_vent_sessions**: Total number of ventilation sessions

### Renal Replacement Therapy (RRT)
- **rrt_required**: Required RRT (1=Yes, 0=No)
- **rrt_types**: Types of RRT received (comma-separated)
- **rrt_sessions**: Total RRT sessions
- **rrt_hours**: Total RRT hours
- **crrt_sessions**: CRRT sessions count
- **cvvhdf_sessions**: CVVHDF sessions count
- **cvvhd_sessions**: CVVHD sessions count
- **cvvh_sessions**: CVVH sessions count
- **ihd_sessions**: IHD sessions count
- **peritoneal_sessions**: Peritoneal dialysis sessions count
- **scuf_sessions**: SCUF sessions count

### ICU Readmissions
- **icu_readmission**: ICU readmission (1=Yes, 0=No)
- **prior_icu_stays**: Number of prior ICU stays
- **icu_admission_number**: ICU admission sequence number (1, 2, 3...)

## Notes
- All time-based fields are in days unless specified otherwise
- Missing values are represented as empty cells or NULL
- File size: 36MB (CSV format)
- Complete dataset with all intended outcome variables preserved