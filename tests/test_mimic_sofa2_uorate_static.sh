#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage_sql="${repo_root}/sofa2_sql/02_stage_components.sql"
score_sql="${repo_root}/sofa2_sql/03_hourly_raw_scores.sql"
window_sql="${repo_root}/sofa2_sql/04_window_final_scores.sql"
firstday_sql="${repo_root}/sofa2_sql/06_first_day_sofa2_simple.sql"
sofa2_sepsis_sql="${repo_root}/sofa2_sql/07_sepsis3_sofa2_delta.sql"
sofa1_sepsis_sql="${repo_root}/sofa2_sql/08_sepsis3_sofa1_delta.sql"
outcome_sql="${repo_root}/sofa2_sql/09_extract_outcomes_final_corrected.sql"
readme="${repo_root}/README.md"
runner="${repo_root}/run_steps.sh"
shadow_runner="${repo_root}/run_steps_shadow.sh"
preflight_sql="${repo_root}/tests/preflight_mimic_sofa2_rebuild.sql"
shadow_validation_sql="${repo_root}/tests/validate_shadow_promotion.sql"

grep -q "mimiciv_derived\\.urine_output_rate" "${stage_sql}"
grep -q "uo_mlkghr_6hr" "${stage_sql}"
grep -q "uo_tm_12hr" "${stage_sql}"
grep -q "urineoutput_12hr" "${stage_sql}"

if sed -n '/sofa2_stage1_urine AS/,/CREATE INDEX idx_st1_urine/p' "${stage_sql}" \
    | grep -q "mimiciv_derived\\.urine_output uo"; then
  echo "sofa2_stage1_urine must not rebuild rates from mimiciv_derived.urine_output" >&2
  exit 1
fi

grep -q "uo_mlkghr_6hr_min" "${score_sql}"
grep -q "anuria_12h_official" "${score_sql}"
grep -q "platelet_min_strict" "${stage_sql}"
grep -q "platelet_min_lab48" "${stage_sql}"
grep -q "bilirubin_max_strict" "${stage_sql}"
grep -q "bilirubin_max_lab48" "${stage_sql}"
grep -q "platelet_strict24_has_evidence" "${window_sql}"
grep -q "bilirubin_strict24_has_evidence" "${window_sql}"
grep -q "sofa2_total_lab48_rescue" "${window_sql}"
grep -q "sofa2_total_strict24" "${firstday_sql}"
if grep -q "MAX(sofa2_total" "${firstday_sql}"; then
  echo "first-day SOFA-2 totals must be SUM(per-organ first-day maxima), not MAX(hourly total)" >&2
  exit 1
fi
grep -q "COALESCE(brain, 0)" "${firstday_sql}"
grep -q "COALESCE(respiratory, 0)" "${firstday_sql}"
grep -q "COALESCE(cardiovascular, 0)" "${firstday_sql}"
grep -q "COALESCE(kidney, 0)" "${firstday_sql}"
grep -q "COALESCE(liver_lab48_rescue, 0)" "${firstday_sql}"
grep -q "COALESCE(hemostasis_lab48_rescue, 0)" "${firstday_sql}"
grep -q "urine_output_rate" "${readme}"
grep -q "lab48_rescue_kidney_uorate" "${readme}"
grep -q "run_step \"00_create_icustay_hourly_basedon_icuintime\"" "${runner}"
grep -q "run_step \"08_sepsis3_sofa1_delta\"" "${runner}"
grep -q "run_step \"09_extract_outcomes_final_corrected\"" "${runner}"
grep -q "sepsis3_sofa2_delta" "${sofa2_sepsis_sql}"
grep -q "sepsis3_sofa1_delta" "${sofa1_sepsis_sql}"
grep -q "mimiciv_derived\\.sepsis3_sofa1_delta" "${outcome_sql}"
grep -q "mimiciv_derived\\.sepsis3_sofa2_delta" "${outcome_sql}"
grep -q "mimiciv_derived\\.sepsis3_definitions_current" "${outcome_sql}"
grep -q "sepsis3_sofa1_official_absolute" "${outcome_sql}"
grep -q "sepsis3_primary_delta_any" "${outcome_sql}"
grep -q "sofa2_total_lab48_rescue AS sofa2_total" "${outcome_sql}"
grep -q "liver_lab48_rescue AS liver" "${outcome_sql}"
grep -q "hemostasis_lab48_rescue AS hemostasis" "${outcome_sql}"
grep -q "mimiciv_team\\.survival_outcomes" "${outcome_sql}"
grep -q "survival_outcomes AS" "${outcome_sql}"
grep -q "so.event_status" "${outcome_sql}"
grep -q "so.survival_days" "${outcome_sql}"
grep -q "so.os_28d_status AS icu_death_within_28_days" "${outcome_sql}"
grep -q "sepsis3_primary_delta_any" "${readme}"
test -f "${shadow_runner}"
test -f "${preflight_sql}"
test -f "${shadow_validation_sql}"
grep -q "TARGET_SCHEMA" "${shadow_runner}"
grep -q "mimiciv_derived" "${shadow_runner}"
grep -q "Refusing to run against production schema" "${shadow_runner}"
grep -q "sepsis3_definitions_current" "${shadow_runner}"
grep -q "sofa1_hourly_current" "${preflight_sql}"
grep -q "row count %, expected at least 1000000" "${preflight_sql}"
grep -q "mimiciv_derived.sepsis3" "${preflight_sql}"
grep -q "mimiciv_derived.ventilation" "${preflight_sql}"
grep -q "mimiciv_team.survival_outcomes" "${preflight_sql}"
grep -q "SUM(per-organ first-day maxima)" "${shadow_validation_sql}"
grep -q "SOFA-2 delta sepsis recomputation" "${shadow_validation_sql}"
grep -q "SOFA-1 delta sepsis recomputation" "${shadow_validation_sql}"
grep -q "sepsis3_definitions_current mismatches shadow delta tables" "${shadow_validation_sql}"
grep -q "Refusing to validate with production schema" "${shadow_validation_sql}"
grep -q "%I.validation_current_vs_shadow_sofa2_first_day_diff" "${shadow_validation_sql}"

if compgen -G "${repo_root}/sofa2_sql/review_check_*.sql" > /dev/null; then
  echo "review_check SQL files must stay under sofa2_sql/archive/review_checks" >&2
  exit 1
fi

test -f "${repo_root}/sofa2_sql/archive/README.md"
test -f "${repo_root}/sofa2_sql/archive/2026-06-18_legacy_kidney_patch/PATCH_kidney_three_rate.md"
