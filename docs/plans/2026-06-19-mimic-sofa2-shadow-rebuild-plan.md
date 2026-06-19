# MIMIC-IV SOFA-2 Shadow Rebuild Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild the MIMIC-IV SOFA-2 foundation artifacts through a versioned shadow path, validate them independently, and promote current views only after explicit approval.

**Architecture:** Keep production `mimiciv_derived.*_current` untouched during rebuild. Build all new artifacts into a versioned shadow schema first, validate row counts, first-day aggregation, sepsis flags, outcome joins, and current-vs-shadow differences, then promote views by a separate gated SQL step.

**Tech Stack:** PostgreSQL 14+, `psql`, shell scripts, static shell tests, MIMIC-IV v3.1 derived schema, local governed SOFA-1 views, `mimiciv_team.survival_outcomes`.

## Non-Negotiable Rules

- Do not run `run_steps.sh` against production for this rebuild.
- Do not drop or overwrite production tables before shadow validation passes.
- Do not promote current views without explicit user confirmation.
- Treat `sepsis3_primary_delta_any` as a selectable legacy-named delta-union flag, not as a universal primary cohort.
- First-day SOFA-2 total is `SUM(per-organ first-day maxima)`, never `MAX(hourly total)`.

## Phase 1: Repo-Side Hardening

### Task 1: Extend Static Guards

**Files:**
- Modify: `tests/test_mimic_sofa2_uorate_static.sh`

**Steps:**
1. Require `06_first_day_sofa2_simple.sql` to reject `MAX(sofa2_total...)`.
2. Require first-day total formula to contain component-max summation.
3. Require `COALESCE` or equivalent non-null defense in first-day total formulas.
4. Require `09_extract_outcomes_final_corrected.sql` to document local SOFA-1 current-view prerequisites.
5. Run:
   ```bash
   bash tests/test_mimic_sofa2_uorate_static.sh
   ```
   Expected: pass.

### Task 2: Harden First-Day SOFA-2 SQL

**Files:**
- Modify: `sofa2_sql/06_first_day_sofa2_simple.sql`

**Steps:**
1. Keep the `organ_max` CTE.
2. Compute totals using `COALESCE(component,0)` summands.
3. Keep policy-specific total columns:
   - `sofa2_total_lab48_rescue`
   - `sofa2_total_strict24`
   - `sofa2_total_full48_exploratory`
4. Keep comments stating total is `SUM(per-organ first-day maxima)`.
5. Run static test.

### Task 3: Make Outcome Export Source Policy Explicit

**Files:**
- Modify: `sofa2_sql/09_extract_outcomes_final_corrected.sql`

**Steps:**
1. In `sofa2_info`, use policy-qualified SOFA-2 first-day fields where available.
2. Document that the direct pipeline reads the just-built first-day table; the shadow pipeline must use the shadow first-day table.
3. Add comments that survival endpoints should use or be validated against `mimiciv_team.survival_outcomes`.
4. Do not change production DB in this task.

## Phase 2: Shadow Execution Scaffold

### Task 4: Add Shadow Runner

**Files:**
- Create: `run_steps_shadow.sh`

**Steps:**
1. Require an explicit target schema argument or environment variable:
   ```bash
   TARGET_SCHEMA=sofa_gov_20260619_rebuild_v1 bash run_steps_shadow.sh
   ```
2. Refuse to run if `TARGET_SCHEMA` is empty or equals `mimiciv_derived`.
3. Create the target schema if absent.
4. Execute shadow SQL wrappers or generated SQL into the target schema.
5. Do not drop production `mimiciv_derived` tables.

### Task 5: Add Preflight SQL

**Files:**
- Create: `tests/preflight_mimic_sofa2_rebuild.sql`

**Checks:**
1. `mimiciv_derived.sofa1_hourly_current` exists and has rows.
2. `mimiciv_derived.sofa_first_day_current` exists and has 94,458 stays.
3. `mimiciv_derived.urine_output_rate` exists and has rows.
4. `mimiciv_team.survival_outcomes` exists and has 94,458 stays.
5. Current governed SOFA-2 manifest has active policy `lab48_rescue_kidney_uorate`.

**Run:**
```bash
psql -h 172.19.160.1 -U postgres -d mimiciv_31 -v ON_ERROR_STOP=1 -f tests/preflight_mimic_sofa2_rebuild.sql
```

### Task 6: Add Shadow Validation SQL

**Files:**
- Create: `tests/validate_shadow_promotion.sql`

**Checks:**
1. Shadow hourly row count and stay count match expected values.
2. Shadow first-day row count and stay count are 94,458.
3. First-day organ scores equal 0-23h per-organ maxima from shadow hourly table.
4. First-day total equals `SUM(per-organ first-day maxima)`.
5. Shadow patient outcome SOFA-2 score equals shadow first-day total.
6. Shadow SOFA-2 delta sepsis flags can be recomputed from shadow hourly scores.
7. Shadow SOFA-1 delta sepsis flags can be recomputed from local SOFA-1 current views.
8. Shadow survival fields either come from `mimiciv_team.survival_outcomes` or match it exactly for governed endpoints.
9. Current-vs-shadow difference tables are created for review.

**Run:**
```bash
psql -h 172.19.160.1 -U postgres -d mimiciv_31 \
  -v ON_ERROR_STOP=1 \
  -v shadow_schema=sofa_gov_20260619_rebuild_v1 \
  -f tests/validate_shadow_promotion.sql
```

## Phase 3: DB Shadow Rebuild

### Task 7: Freeze Current State

**Output:**
- Create directory: `docs/freeze_20260619/`

**Export:**
1. Current view definitions.
2. Active governance manifest.
3. Row counts and stay counts for all current score/outcome views.
4. DB comments for current sepsis/outcome tables.
5. Known mismatch report:
   - `patient_outcomes.sofa2_score` vs `sofa2_first_day_current."SOFA_2"`.

No production writes in this task.

### Task 8: Run Shadow Rebuild

**Command:**
```bash
TARGET_SCHEMA=sofa_gov_20260619_rebuild_v1 bash run_steps_shadow.sh
```

**Requirement:** This is allowed only after Tasks 1-7 pass.

### Task 9: Run Shadow Validation

Run `tests/validate_shadow_promotion.sql`.

If any validation fails, stop. Do not promote.

## Phase 4: Promotion Gate

### Task 10: Prepare Promotion SQL

**Files:**
- Create: `sql/promote_sofa_gov_20260619_rebuild_v1.sql`

**Contents:**
1. Update current views to point to shadow artifacts.
2. Update governance manifest.
3. Add comments to old artifacts: `do not use as current`.
4. Do not drop old artifacts in the same step.

### Task 11: Explicit User Confirmation

Before executing promotion SQL, ask for confirmation because this changes database current views.

### Task 12: Promote and Verify

After confirmation:
1. Run promotion SQL.
2. Run post-promotion validation.
3. Confirm:
   - current SOFA-2 first-day total matches shadow.
   - current `patient_outcomes` SOFA-2 score matches current first-day SOFA-2.
   - active manifest points to the new version.

## Phase 5: Commit and Push

Only after repo tests, shadow validation, and user-approved promotion pass:

1. `git status --short`
2. `git diff`
3. Commit with a message describing the governed rebuild.
4. Push only after explicit user confirmation.
