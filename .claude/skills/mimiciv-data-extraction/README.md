# MIMIC-IV Data Extraction Skill

A comprehensive Claude skill for extracting raw data from the MIMIC-IV database, focused on PostgreSQL queries, clinical concepts, and research workflows.

## Overview

This skill provides expert guidance for working with MIMIC-IV (Medical Information Mart for Intensive Care IV), a large, freely-available database of de-identified health data from patients admitted to Beth Israel Deaconess Medical Center.

## What This Skill Covers

### Database Structure
- Complete schema documentation for all MIMIC-IV modules (hosp, icu, ed, cxr)
- Table relationships and foreign keys
- Primary keys and indexing strategies

### Data Extraction Patterns
- Patient cohort selection
- Time-series data extraction (vital signs, labs, medications)
- Laboratory data with reference ranges
- Medication exposure windows
- Diagnosis and procedure code queries

### Clinical Concepts
- **SOFA Score**: Sequential Organ Failure Assessment calculation
- **Sepsis-3 Criteria**: Infection detection and organ dysfunction scoring
- **Acute Kidney Injury (AKI)**: KDIGO criteria implementation
- **Mechanical Ventilation**: Detection and duration calculation
- **First Day Measurements**: 24-hour summary statistics

### Advanced Topics
- Data quality assessment and outlier detection
- Missing data handling strategies
- Query performance optimization
- Duplicate record management
- Common itemid references for quick lookup

## How to Use This Skill

### Activating the Skill

In Claude Code, invoke the skill by typing:
```
/skill mimiciv-data-extraction
```

Or reference it in your conversation when working with MIMIC-IV data.

### Example Use Cases

**1. Build a Sepsis Cohort**
```
"Using the mimiciv-data-extraction skill, help me build a SQL query to identify
sepsis patients using Sepsis-3 criteria with SOFA scores and infection markers."
```

**2. Extract Time-Series Vital Signs**
```
"I need to extract hourly vital signs (heart rate, blood pressure, SpO2) for
ICU patients in my cohort. Show me the optimal query pattern."
```

**3. Calculate SOFA Scores**
```
"Help me write SQL to calculate first-day SOFA scores for my patient cohort,
including all six components."
```

**4. Detect Acute Kidney Injury**
```
"Show me how to implement KDIGO criteria for AKI detection using both
creatinine and urine output criteria."
```

## Key Features

### Comprehensive Table Documentation
- Detailed schema for 50+ MIMIC-IV tables
- Column descriptions and data types
- Foreign key relationships
- Common query patterns for each table

### Clinical Concept Library
Pre-built SQL patterns for:
- SOFA score (all 6 components)
- Sepsis-3 detection
- KDIGO AKI staging
- Mechanical ventilation
- Vasopressor use
- Comorbidity extraction (Charlson)

### Performance Optimization
- Indexing recommendations
- Query optimization strategies
- Best practices for large table queries (chartevents, labevents)
- Memory-efficient extraction methods

### ItemID Reference Guide
Quick lookup for common itemids:
- Vital signs (heart rate, blood pressure, temperature, etc.)
- Laboratory tests (creatinine, hemoglobin, platelets, etc.)
- Ventilator settings (PEEP, FiO2, tidal volume)
- Urine output measurements

## Project Integration

This skill is designed to work seamlessly with your existing MIMIC-IV PostgreSQL setup. It complements:

- `utils/db_helper.py` - Database connection utilities
- Your research scripts for SOFA/sepsis/AKI analysis
- Data extraction and preprocessing workflows

## Quick Reference: Common Queries

### Get ICU Patient Demographics
```sql
SELECT ie.stay_id, p.gender, p.anchor_age, ie.los
FROM mimiciv_icu.icustays ie
JOIN mimiciv_hosp.patients p ON ie.subject_id = p.subject_id
WHERE ie.los >= 1;
```

### Extract Lab Values with Flags
```sql
SELECT le.charttime, di.label, le.valuenum, le.flag
FROM mimiciv_hosp.labevents le
JOIN mimiciv_hosp.d_labitems di ON le.itemid = di.itemid
WHERE le.hadm_id = ? AND di.label = 'Creatinine';
```

### Get First 24-Hour Vital Signs
```sql
SELECT ce.charttime, di.label, ce.valuenum
FROM mimiciv_icu.chartevents ce
JOIN mimiciv_icu.d_items di ON ce.itemid = di.itemid
JOIN mimiciv_icu.icustays ie ON ce.stay_id = ie.stay_id
WHERE ce.stay_id = ?
  AND ce.charttime BETWEEN ie.intime AND ie.intime + INTERVAL '24 hours'
  AND ce.itemid IN (220045, 220210, 220277, 220181);
```

## Data Sources

This skill is built from:
- **MIMIC-IV Official Documentation**: https://mimic.mit.edu/docs/iv/
- **MIMIC Code Repository**: https://github.com/MIT-LCP/mimic-code
- Clinical research best practices and validated SQL patterns

## Requirements

- Access to MIMIC-IV database (PostgreSQL or BigQuery)
- Basic SQL knowledge
- Understanding of clinical concepts (helpful but not required)

## Version

**Current Version**: 1.0.0
**Last Updated**: November 2025
**Focus**: Raw data extraction from MIMIC-IV PostgreSQL

## Support

For questions about MIMIC-IV:
- MIMIC Documentation: https://mimic.mit.edu/docs/iv/
- MIMIC User Group: https://groups.google.com/forum/#!forum/mimicdata
- PhysioNet: https://physionet.org/

---

**Created for**: Clinical researchers working with MIMIC-IV data
**Best for**: SQL query development, clinical concept implementation, data extraction pipelines
