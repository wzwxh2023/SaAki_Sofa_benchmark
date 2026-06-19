# MIMIC-IV SOFA 2026-06-19 Intermediate Cleanup Plan

Date: 2026-06-19

Status: executed on 2026-06-19 after explicit user approval.

## Purpose

After the governed MIMIC-IV SOFA promotion, the database still contains
reproducible intermediate SOFA-2 stage tables. They are useful during rebuilds
but should not remain prominent in the main schema because they obscure the
current interfaces and occupy unnecessary disk space.

This cleanup keeps the final/current promoted tables and preserves a slim shadow
audit snapshot.

## Cleanup Principles

- Do not drop current interfaces.
- Do not drop current promoted artifact tables.
- Do not drop the full shadow schema.
- Drop only explicit white-listed intermediate tables.
- Refuse to run unless the approval token is supplied.
- Refuse to run if any current `mimiciv_derived` view depends on a cleanup
  candidate.
- Leave comments on retained shadow audit objects explaining that they are not
  downstream current sources.

## Main Schema Cleanup

Drop these reproducible intermediate tables from `mimiciv_derived`:

- `sofa2_stage1_brain`
- `sofa2_stage1_coag`
- `sofa2_stage1_delirium`
- `sofa2_stage1_kidney_labs`
- `sofa2_stage1_liver`
- `sofa2_stage1_mech`
- `sofa2_stage1_oxygen`
- `sofa2_stage1_resp_support`
- `sofa2_stage1_rrt`
- `sofa2_stage1_sedation`
- `sofa2_stage1_urine`

Fresh read-only inventory before script creation showed 11 such tables in
`mimiciv_derived`, totaling about 7 GB. They had 0 dependency edges from current
`mimiciv_derived` views.

## Shadow Schema Slimming

Keep these shadow audit outputs in `sofa_gov_20260619_rebuild_v1`:

- `first_day_sofa2`
- `sofa2_scores_hr_filtered`
- `patient_outcomes`
- `sepsis3_definitions_current`
- `sepsis3_sofa1_delta`
- `sepsis3_sofa2_delta`
- `validation_current_vs_shadow_sofa2_first_day_diff`

Drop these reproducible shadow intermediates:

- `icustay_hourly_basedon_icuintime`
- `sofa2_hourly_raw`
- `sofa2_scores`
- `sofa2_stage1_brain`
- `sofa2_stage1_coag`
- `sofa2_stage1_delirium`
- `sofa2_stage1_kidney_labs`
- `sofa2_stage1_liver`
- `sofa2_stage1_mech`
- `sofa2_stage1_oxygen`
- `sofa2_stage1_resp_support`
- `sofa2_stage1_rrt`
- `sofa2_stage1_sedation`
- `sofa2_stage1_urine`

Fresh read-only inventory before script creation showed the full shadow schema
at about 16 GB. The retained audit subset was about 1.5 GB, with about 11 GB of
drop candidates.

## Execution Script

Prepared script:

```text
sql/cleanup_sofa_gov_20260619_intermediates.sql
```

Required execution form:

```bash
psql -h 172.19.160.1 -U postgres -d mimiciv_31 -X \
  -v ON_ERROR_STOP=1 \
  -v confirm_cleanup=I_APPROVE_SOFA_GOV_20260619_INTERMEDIATE_CLEANUP \
  -f sql/cleanup_sofa_gov_20260619_intermediates.sql
```

This command was executed successfully on 2026-06-19. The script completed with:

```text
SOFA 2026-06-19 intermediate cleanup completed
```

## Verification

Static guard:

```bash
bash tests/test_sofa_gov_cleanup_static.sh
```

After execution, rerun:

```bash
psql -h 172.19.160.1 -U postgres -d mimiciv_31 -X \
  -v ON_ERROR_STOP=1 \
  -f tests/validate_post_promotion_sofa_gov_20260619.sql
```

Fresh verification after execution:

- `tests/validate_post_promotion_sofa_gov_20260619.sql`: exit 0; final status
  `Post-promotion validation completed`.
- `tests/test_sofa_gov_cleanup_static.sh`: exit 0.
- `git diff --check`: exit 0.
- `mimiciv_derived` `sofa2_stage1*` relation count: 0.
- `sofa_gov_20260619_rebuild_v1` retained table/view relation count: 7.
- retained shadow table size: 1487 MB.
- retained full shadow schema size including indexes: 1759 MB.
