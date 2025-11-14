# SOFA-2 Implementation for MIMIC-IV

This folder contains SQL scripts for calculating SOFA-2 scores based on the JAMA 2025 publication (Ranzani et al., 2025).

## 📋 Overview

**SOFA-2** is the first major update to the Sequential Organ Failure Assessment score in 30 years. Key improvements include:

1. **Better cardiovascular system scoring** - Combined norepinephrine+epinephrine dosing
2. **Updated respiratory thresholds** - New PaO2/FiO2 cutoffs with advanced respiratory support
3. **Enhanced renal scoring** - RRT criteria with metabolic indicators
4. **Delirium integration** - Brain/neurological scoring includes delirium medications
5. **New terminology** - "Brain" instead of "CNS", "Hemostasis" instead of "Coagulation"

## 📁 File Structure

```
sofa2_sql/
├── README.md                          # This file
├── 00_helper_views.sql               # Helper views for SOFA-2 specific components
├── sofa2.sql                         # Hourly SOFA-2 calculation (like sofa.sql)
├── first_day_sofa2.sql               # First 24h SOFA-2 (like first_day_sofa.sql)
├── sepsis3_sofa2.sql                 # Sepsis-3 using SOFA-2 criteria
└── validation/
    ├── compare_sofa1_sofa2.sql       # Side-by-side comparison
    └── expected_distributions.sql     # Check if distributions match JAMA paper
```

## 🔑 Key Differences from SOFA-1

### 1. Brain/Neurological (renamed from CNS)
| Change | SOFA-1 | SOFA-2 |
|--------|--------|--------|
| **Delirium meds** | Not considered | +1 point if on haloperidol, quetiapine, olanzapine, risperidone |
| **GCS thresholds** | Same | Same (no change) |

### 2. Respiratory System ⭐ Major Update
| Score | SOFA-1 | SOFA-2 |
|-------|--------|--------|
| **4** | PF <100 with vent | PF ≤75 with advanced support **OR ECMO** |
| **3** | PF <200 with vent | PF ≤150 with advanced support |
| **2** | PF <300 (any) | PF ≤225 |
| **1** | PF <400 (any) | PF ≤300 |

**New**: "Advanced respiratory support" = HFNC, CPAP, BiPAP, NIV, IMV

### 3. Cardiovascular System ⭐⭐ BIGGEST CHANGE
| Score | SOFA-1 | SOFA-2 |
|-------|--------|--------|
| **4** | Dop >15 OR Epi >0.1 OR NE >0.1 | **NE+Epi >0.4** OR mechanical support |
| **3** | Dop >5 OR Epi ≤0.1 OR NE ≤0.1 | **NE+Epi 0.2-0.4** OR low+other |
| **2** | Any Dop OR Any Dob | **NE+Epi ≤0.2** OR any other vasopressor |
| **1** | MAP <70 | MAP <70 (no change) |

**New**:
- Combines norepinephrine + epinephrine doses
- Mechanical circulatory support = ECMO, IABP, LVAD, Impella
- Special dopamine-only scoring (2pts: ≤20, 3pts: 20-40, 4pts: >40 μg/kg/min)

### 4. Liver
| Score | SOFA-1 | SOFA-2 |
|-------|--------|--------|
| **0** | Bilirubin <1.2 | Bilirubin **≤1.2** (changed from < to ≤) |
| **1-4** | Same thresholds | Same thresholds |

### 5. Kidney ⭐ Important Update
| Score | SOFA-1 | SOFA-2 |
|-------|--------|--------|
| **4** | Cr ≥5.0 OR UO <200ml/24h | **RRT or meets RRT criteria** |
| **3** | Cr 3.5-5.0 OR UO <500ml/24h | Cr >3.5 OR **UO <0.3 ml/kg/h ≥24h** OR anuria ≥12h |
| **2** | Cr 2.0-3.5 | Cr ≤3.5 OR **UO <0.5 ml/kg/h ≥12h** |
| **1** | Cr 1.2-2.0 | Cr ≤2.0 OR **UO <0.5 ml/kg/h 6-12h** |

**RRT Criteria** (for patients NOT on RRT):
- Cr >1.2 mg/dL + (K ≥6.0 mmol/L OR pH ≤7.2 + HCO3 ≤12 mmol/L)

**New**:
- Weight-based urine output (ml/kg/h instead of total ml)
- Metabolic criteria for RRT indication

### 6. Hemostasis/Coagulation
| Score | SOFA-1 | SOFA-2 |
|-------|--------|--------|
| **4** | PLT <20 | PLT **≤50** |
| **3** | PLT <50 | PLT **≤80** |
| **2** | PLT <100 | PLT ≤100 (no change) |
| **1** | PLT <150 | PLT ≤150 (no change) |

## 🎯 MIMIC-IV Tables Used

### Original SOFA Tables (still used):
- `mimiciv_derived.icustay_hourly` - Hourly time grid
- `mimiciv_derived.bg` - Blood gases (PaO2/FiO2)
- `mimiciv_derived.vitalsign` - MAP
- `mimiciv_derived.gcs` - Glasgow Coma Scale
- `mimiciv_derived.enzyme` - Bilirubin
- `mimiciv_derived.chemistry` - Creatinine
- `mimiciv_derived.complete_blood_count` - Platelets
- `mimiciv_derived.urine_output_rate` - Urine output
- `mimiciv_derived.norepinephrine`, `epinephrine`, `dopamine`, `dobutamine` - Vasopressors

### New SOFA-2 Specific Data Needed:
- `mimiciv_hosp.prescriptions` - Delirium medications
- `mimiciv_derived.ventilation` - Advanced respiratory support types
- `mimiciv_icu.procedureevents` - ECMO, IABP, LVAD, RRT procedures
- `mimiciv_hosp.labevents` - Potassium, pH, bicarbonate (for RRT criteria)
- `mimiciv_icu.inputevents` - Vasopressin, phenylephrine (other vasopressors)

## 📊 Expected SOFA-2 Distribution

Based on Ranzani et al., JAMA 2025:

**Key Validation Metrics**:
- **Cardiovascular 2-point**: Should be ~8.9% (vs 0.9% in SOFA-1)
- **Median total score**: 3 (IQR 1-5)
- **AUROC for mortality**: 0.79-0.81

## 🚀 Usage

### 1. Create Helper Views (run once)
```sql
\i sofa2_sql/00_helper_views.sql
```

### 2. Calculate SOFA-2 Hourly
```sql
\i sofa2_sql/sofa2.sql
```

### 3. Calculate First Day SOFA-2
```sql
\i sofa2_sql/first_day_sofa2.sql
```

### 4. Identify Sepsis-3 with SOFA-2
```sql
\i sofa2_sql/sepsis3_sofa2.sql
```

### 5. Validate Results
```sql
\i sofa2_sql/validation/compare_sofa1_sofa2.sql
```

## ⚠️ Important Notes

### Missing Data Handling
- **Day 1 (Baseline)**: Missing values = 0 points (normal)
- **Subsequent Days**: Use LOCF (Last Observation Carried Forward)

### ECMO Scoring
- **Respiratory ECMO**: Respiratory system = 4 points, cardiovascular = not scored
- **Cardiac ECMO**: Both systems scored

### Dopamine Special Scoring
When dopamine is the **only** vasopressor:
- 2 pts: ≤20 μg/kg/min
- 3 pts: >20-40 μg/kg/min
- 4 pts: >40 μg/kg/min

### Norepinephrine Salt Conversion
MIMIC-IV may use different salts. Convert to base:
- 1 mg base = 2 mg bitartrate monohydrate
- 1 mg base = 1.89 mg anhydrous tartrate
- 1 mg base = 1.22 mg hydrochloride

## 📚 References

1. **Ranzani OT, Singer M, Salluh JIF, et al.** Development and Validation of the Sequential Organ Failure Assessment (SOFA)-2 Score. *JAMA*. 2025. doi:10.1001/jama.2025.20516

2. **Moreno R, Rhodes A, Ranzani O, et al.** Rationale and Methodological Approach Underlying Development of the SOFA-2 Score. *JAMA Netw Open*. 2025. doi:10.1001/jamanetworkopen.2025.45040

3. **Original SOFA**: Vincent JL, et al. The SOFA (Sepsis-related Organ Failure Assessment) score to describe organ dysfunction/failure. *Intensive Care Med*. 1996;22(7):707-710.

## 📧 Contact

For questions about this implementation, refer to:
- SOFA-2 standard: `/mnt/f/SaAki_Sofa_benchmark/SOFA2_评分标准详解.md`
- Research plan: `/mnt/f/SaAki_Sofa_benchmark/研究方案_SOFA2_SA-AKI_Letter.md`
- Quick execution plan: `/mnt/f/SaAki_Sofa_benchmark/快速执行计划_Letter产出.md`
