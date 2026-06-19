#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage_sql="${repo_root}/sofa2_sql/02_stage_components.sql"
score_sql="${repo_root}/sofa2_sql/03_hourly_raw_scores.sql"
window_sql="${repo_root}/sofa2_sql/04_window_final_scores.sql"
firstday_sql="${repo_root}/sofa2_sql/06_first_day_sofa2_simple.sql"
readme="${repo_root}/README.md"
runner="${repo_root}/run_steps.sh"

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
grep -q "urine_output_rate" "${readme}"
grep -q "lab48_rescue_kidney_uorate" "${readme}"
grep -q "run_step \"00_create_icustay_hourly_basedon_icuintime\"" "${runner}"
grep -q "run_step \"09_update_sepsis3_SOFA1\"" "${runner}"

if compgen -G "${repo_root}/sofa2_sql/review_check_*.sql" > /dev/null; then
  echo "review_check SQL files must stay under sofa2_sql/archive/review_checks" >&2
  exit 1
fi

test -f "${repo_root}/sofa2_sql/archive/README.md"
test -f "${repo_root}/sofa2_sql/archive/2026-06-18_legacy_kidney_patch/PATCH_kidney_three_rate.md"
