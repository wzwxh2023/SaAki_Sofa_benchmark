#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cleanup_sql="${repo_root}/sql/cleanup_sofa_gov_20260619_intermediates.sql"

test -f "${cleanup_sql}"

rg -F "I_APPROVE_SOFA_GOV_20260619_INTERMEDIATE_CLEANUP" "${cleanup_sql}" >/dev/null
rg -F "set_config('app.confirm_cleanup'" "${cleanup_sql}" >/dev/null
rg -F "current_setting('app.confirm_cleanup'" "${cleanup_sql}" >/dev/null

if rg -n "DROP SCHEMA|CASCADE|LIKE 'sofa2_stage1%'" "${cleanup_sql}" >/dev/null; then
  echo "cleanup SQL must not use DROP SCHEMA, CASCADE, or wildcard stage-table deletes" >&2
  exit 1
fi

rg -F "cleanup_keep_shadow" "${cleanup_sql}" >/dev/null
rg -F "cleanup_drop_shadow" "${cleanup_sql}" >/dev/null
rg -F "cleanup_drop_main" "${cleanup_sql}" >/dev/null
rg -F "Current mimiciv_derived views still depend on cleanup candidates" "${cleanup_sql}" >/dev/null
rg -F "Active governance manifest points directly to shadow schema" "${cleanup_sql}" >/dev/null

main_stage_count="$(rg -c '^DROP TABLE mimiciv_derived\.sofa2_stage1_' "${cleanup_sql}")"
shadow_drop_count="$(rg -c '^DROP TABLE sofa_gov_20260619_rebuild_v1\.' "${cleanup_sql}")"

if [[ "${main_stage_count}" -ne 11 ]]; then
  echo "expected 11 explicit mimiciv_derived sofa2_stage1 drops, got ${main_stage_count}" >&2
  exit 1
fi

if [[ "${shadow_drop_count}" -ne 14 ]]; then
  echo "expected 14 explicit shadow intermediate drops, got ${shadow_drop_count}" >&2
  exit 1
fi

rg -F "COMMENT ON SCHEMA sofa_gov_20260619_rebuild_v1" "${cleanup_sql}" >/dev/null
rg -F "not the current downstream source" "${cleanup_sql}" >/dev/null
