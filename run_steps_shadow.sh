#!/usr/bin/env bash
set -euo pipefail

unset PGPASSWORD

DB_HOST="${DB_HOST:-localhost}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-mimiciv}"
TARGET_SCHEMA="${TARGET_SCHEMA:-}"

if [[ -z "${TARGET_SCHEMA}" ]]; then
  echo "TARGET_SCHEMA is required, e.g. TARGET_SCHEMA=sofa_gov_20260619_rebuild_v1 bash run_steps_shadow.sh" >&2
  exit 1
fi

if [[ "${TARGET_SCHEMA}" == "mimiciv_derived" ]]; then
  echo "Refusing to run against production schema mimiciv_derived" >&2
  exit 1
fi

if [[ ! "${TARGET_SCHEMA}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "TARGET_SCHEMA must be a simple PostgreSQL identifier" >&2
  exit 1
fi

pipeline_tables=(
  icustay_hourly_basedon_icuintime
  sofa2_stage1_sedation
  sofa2_stage1_vent
  sofa2_stage1_sf
  sofa2_stage1_mech
  sofa2_stage1_bilirubin
  sofa2_stage1_kidney_labs
  sofa2_stage1_rrt
  sofa2_stage1_urine
  sofa2_stage1_platelets
  sofa2_stage1_delirium
  sofa2_stage1_brain
  sofa2_stage1_resp_support
  sofa2_stage1_oxygen
  sofa2_stage1_coag
  sofa2_stage1_liver
  sofa2_hourly_raw
  sofa2_scores
  sofa2_scores_hr_filtered
  first_day_sofa2
  sepsis3_sofa2_delta
  sepsis3_sofa1_delta
  sepsis3_definitions_current
  patient_outcomes
)

steps=(
  00_create_icustay_hourly_basedon_icuintime
  01_setup_cleanup
  02_stage_components
  03_hourly_raw_scores
  04_window_final_scores
  05_filter_hr_nonnegative
  06_first_day_sofa2_simple
  07_sepsis3_sofa2_delta
  08_sepsis3_sofa1_delta
  09_extract_outcomes_final_corrected
)

run_psql() {
  psql -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 "$@"
}

rewrite_sql() {
  local input_file="$1"
  local output_file="$2"

  cp "${input_file}" "${output_file}"
  for table_name in "${pipeline_tables[@]}"; do
    TARGET_SCHEMA="${TARGET_SCHEMA}" TABLE_NAME="${table_name}" perl -0pi -e '
      my $schema = $ENV{"TARGET_SCHEMA"};
      my $table = $ENV{"TABLE_NAME"};
      s/\bmimiciv_derived\.\Q$table\E\b/$schema.$table/g;
    ' "${output_file}"
  done
}

echo "====== SOFA2 shadow rebuild ======"
echo "Target schema: ${TARGET_SCHEMA}"

run_psql -c "CREATE SCHEMA IF NOT EXISTS \"${TARGET_SCHEMA}\";"
run_psql -f "tests/preflight_mimic_sofa2_rebuild.sql"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

for step in "${steps[@]}"; do
  input_sql="sofa2_sql/${step}.sql"
  shadow_sql="${tmpdir}/${step}.shadow.sql"
  rewrite_sql "${input_sql}" "${shadow_sql}"
  echo "----------------------------------------"
  echo "[$(date '+%F %T')] shadow step ${step}"
  run_psql -f "${shadow_sql}"
done

echo "====== shadow rebuild complete: ${TARGET_SCHEMA} ======"
