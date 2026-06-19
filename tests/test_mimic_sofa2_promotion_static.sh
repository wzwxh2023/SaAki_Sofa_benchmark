#!/usr/bin/env bash
set -euo pipefail

promotion_sql="sql/promote_sofa_gov_20260619_rebuild_v1.sql"
post_promotion_sql="tests/validate_post_promotion_sofa_gov_20260619.sql"
shadow_validation_sql="tests/validate_shadow_promotion.sql"
approval_token="I_HAVE_REVIEWED_AND_APPROVE_SOFA_GOV_20260619"

test -f "${promotion_sql}"
test -f "${post_promotion_sql}"

rg -F "${approval_token}" "${promotion_sql}" >/dev/null
rg -F "set_config('app.confirm_promotion'" "${promotion_sql}" >/dev/null
rg -F "current_setting('app.confirm_promotion'" "${promotion_sql}" >/dev/null

if rg -n '^\\if .*=' "${promotion_sql}" >/dev/null; then
    echo "Invalid psql conditional: do not use string equality inside \\if" >&2
    exit 1
fi

if rg -n '^[[:space:]]*\\q(uit)?\b' "${promotion_sql}" "${shadow_validation_sql}" >/dev/null; then
    echo "Invalid psql failure gate: use SQL RAISE EXCEPTION instead of \\quit" >&2
    exit 1
fi

rg -F "mimiciv_derived_archive" "${promotion_sql}" >/dev/null
rg -F "validation_current_vs_shadow_sofa2_first_day_diff" "${promotion_sql}" >/dev/null
rg -F "mimiciv_team.survival_outcomes" "${promotion_sql}" >/dev/null
rg -F "sofa_gov_20260619_rebuild_v1.patient_outcomes" "${promotion_sql}" >/dev/null
rg -F "sofa2_total_lab48_rescue" "${promotion_sql}" >/dev/null
rg -F "mimiciv_derived.sofa_first_day_policy_v20260619_current" "${promotion_sql}" >/dev/null
rg -F "mimiciv_derived.sofa2_hourly_policy_v20260619_current" "${promotion_sql}" >/dev/null
rg -F "mimiciv_derived.sofa1_first_day_current" "${promotion_sql}" >/dev/null
rg -F "mimiciv_derived.sofa1_hourly_current" "${promotion_sql}" >/dev/null
rg -F "CREATE OR REPLACE VIEW mimiciv_derived.sofa1_hourly_current" "${promotion_sql}" >/dev/null
if rg -n "local_recomputed_shadow" "${promotion_sql}" >/dev/null; then
    echo "Use current-artifact provenance metadata after promotion, not local_recomputed_shadow" >&2
    exit 1
fi

rg -F "mimiciv_derived.sofa1_first_day_current" "${post_promotion_sql}" >/dev/null
rg -F "mimiciv_derived.sofa1_hourly_current" "${post_promotion_sql}" >/dev/null
rg -F "current views must not depend on shadow schema" "${post_promotion_sql}" >/dev/null
rg -F "mimiciv_derived.patient_outcomes" "${post_promotion_sql}" >/dev/null
rg -F "mimiciv_derived.sofa2_first_day_current" "${post_promotion_sql}" >/dev/null
rg -F "mimiciv_derived.sepsis3_definitions_current" "${post_promotion_sql}" >/dev/null
rg -F "mimiciv_team.survival_outcomes" "${post_promotion_sql}" >/dev/null
rg -F "sofa_gov_20260619_rebuild_v1" "${post_promotion_sql}" >/dev/null
rg -F "RAISE EXCEPTION" "${post_promotion_sql}" >/dev/null
