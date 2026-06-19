# MIMIC-IV SOFA Governance Promotion Execution Record

Date: 2026-06-19

Repository state at record creation: local changes prepared, not committed, not pushed.

Database: `mimiciv_31`

## Purpose

This promotion standardizes the local MIMIC-IV SOFA foundation layer after the
2026-06-19 shadow rebuild. The goal is to expose one unambiguous current version
for MIMIC-IV SOFA-1, MIMIC-IV SOFA-2, patient outcomes, and selectable Sepsis-3
definition tables.

The promotion specifically addresses these prior risks:

- `patient_outcomes` could lag behind the governed SOFA-2 first-day score.
- Some public SQL paths could reproduce an older SOFA-2 first-day total formula.
- Survival endpoints could drift if recalculated in the SOFA engineering layer
  instead of using the local authoritative `mimiciv_team.survival_outcomes`.
- Current and historical artifacts could be difficult to distinguish without a
  database-level governance record.

## Promoted Current Policy

The current MIMIC-IV SOFA-2 implementation promoted on this date uses:

- Platelet and bilirubin `lab48_rescue`: strict 24h evidence first; 48h rescue
  only when strict 24h evidence is absent.
- Kidney urine scoring from official MIMIC-derived `urine_output_rate`.
- First-day total as `SUM(per-organ first-day maxima)`, not `MAX(hourly total)`.
- Virtual RRT creatinine pathway retained as implemented in the governed
  SOFA-2 pipeline.
- Survival and mortality endpoints joined from `mimiciv_team.survival_outcomes`.

The current MIMIC-IV SOFA-1 interfaces retain the local official-derived SOFA-1
current views. Sepsis definitions are selectable; no single sepsis definition is
declared universal for all downstream studies.

## Scope

Database objects promoted or refreshed in `mimiciv_derived`:

- `patient_outcomes`
- `sepsis3_definitions_current`
- `sepsis3_sofa1_delta`
- `sepsis3_sofa2_delta`
- `sofa_first_day_policy_v20260619_current`
- `sofa2_hourly_policy_v20260619_current`

Current interfaces recorded in the active governance manifest:

- `mimiciv_derived.patient_outcomes_sofa_current`
- `mimiciv_derived.sepsis3_definitions_current`
- `mimiciv_derived.sofa_first_day_current`
- `mimiciv_derived.sofa1_first_day_current`
- `mimiciv_derived.sofa1_hourly_current`
- `mimiciv_derived.sofa2_first_day_current`
- `mimiciv_derived.sofa2_hourly_current`

Archived superseded current tables:

- `mimiciv_derived_archive.patient_outcomes_pre_shadow_20260619`
- `mimiciv_derived_archive.sepsis3_definitions_current_pre_shadow_20260619`
- `mimiciv_derived_archive.sepsis3_sofa1_delta_pre_shadow_20260619`
- `mimiciv_derived_archive.sepsis3_sofa2_delta_pre_shadow_20260619`

A pre-existing unversioned archive table was preserved and renamed:

- `mimiciv_derived_archive.sepsis3_sofa2_delta_legacy_pre_shadow_promotion_20260619`

Repository-side scope:

- Harden MIMIC-IV SOFA-2 first-day SQL so reproducible public SQL uses
  `SUM(per-organ first-day maxima)`.
- Make MIMIC-IV outcome extraction depend on `mimiciv_team.survival_outcomes`.
- Add shadow rebuild, promotion, and validation scripts.
- Add freeze, shadow-validation, external-review, and promotion documentation.

## Out Of Scope

This promotion does not:

- Promote or rebuild eICU SOFA-2 final tables.
- Decide whether to keep, compress, or drop the 16 GB shadow schema
  `sofa_gov_20260619_rebuild_v1`.
- Declare one universal sepsis cohort policy for all future studies.
- Update article-specific cohort counts, flowcharts, model results, or AUC
  numbers in the repository README.
- Commit or push repository changes.

## Approval And Review

Promotion was executed only after explicit user approval for database promotion.

External qoderclicn review was performed before promotion. The second pass
returned PASS after fixes for promotion gates, hidden shadow dependencies,
patient-outcome anchoring, and manifest checks.

## Expected Differences Versus Pre-Promotion Current State

Expected and accepted differences:

- `sofa2_first_day_current` versus shadow: 0 differences.
- `sofa2_hourly_current` versus shadow: 0 differences.
- Sepsis current tables versus shadow recomputation: 0 mismatches.
- `patient_outcomes.sofa2_score`: 1,206 rows changed, because the previous
  `patient_outcomes` table lagged the governed SOFA-2 first-day current table.
- `event_status`: 0 differences.
- Survival time and mortality-window fields changed where the old table
  recalculated survival locally instead of using `mimiciv_team.survival_outcomes`.

Survival QA rows are not SOFA missingness. `survival_qa_any_flag=1` identifies
759 outcome-quality anomaly rows from `mimiciv_team.survival_outcomes`; downstream
survival/mortality analyses should filter `survival_qa_any_flag=0` unless the
study has a specific QA-focused reason not to.

## Verification Evidence

Fresh verification after this record was created:

- `tests/validate_post_promotion_sofa_gov_20260619.sql`: exit 0; final status
  `Post-promotion validation completed`.
- `tests/test_mimic_sofa2_promotion_static.sh`: exit 0.
- `tests/test_mimic_sofa2_uorate_static.sh`: exit 0.
- `git diff --check`: exit 0.

Post-promotion validation target:

```bash
psql -h 172.19.160.1 -U postgres -d mimiciv_31 -X \
  -v ON_ERROR_STOP=1 \
  -f tests/validate_post_promotion_sofa_gov_20260619.sql
```

Static validation targets:

```bash
bash tests/test_mimic_sofa2_promotion_static.sh
bash tests/test_mimic_sofa2_uorate_static.sh
git diff --check
```

These checks must be rerun if the SQL, promotion, validation, or documentation
files are changed again before commit or push.
