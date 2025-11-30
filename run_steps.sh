#!/usr/bin/env bash
set -euo pipefail

export PGPASSWORD=188211
DB_HOST="172.19.160.1"
DB_USER="postgres"
DB_NAME="mimiciv_31"

run_step() {
  local step="$1"
  echo "----------------------------------------"
  echo "[$(date '+%F %T')] 开始执行 ${step}"
  psql -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -f "sofa2_sql/${step}.sql"
  echo "[$(date '+%F %T')] 完成 ${step}"
}

echo "====== 开始运行 SOFA2 提取流程 ======"
run_step "01_setup_cleanup"
run_step "02_stage_components"
run_step "03_hourly_raw_scores"
run_step "04_window_final_scores"
run_step "05_filter_hr_nonnegative"
run_step "06_first_day_sofa2_simple"
run_step "07_sepsis3_sofa2_delta"
run_step "08_extract_outcomes_final_corrected"
echo "====== 全部步骤完成 ======"
