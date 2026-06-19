# MIMIC-IV SOFA Promotion Non-Code Review Checklist

Date: 2026-06-19

Purpose: this file is the human review surface for promotion. The user is not expected to review SQL code. The user reviews only the clinical/methodological policies and observed result differences below.

## Confirmed Final Policies

| Area | Final policy | Status |
| --- | --- | --- |
| SOFA-2 platelet/bilirubin | Use `lab48_rescue`: strict 24h evidence first; 48h rescue only when strict 24h evidence is absent. | Confirmed by user |
| SOFA-2 kidney urine | Use official MIMIC-derived `urine_output_rate`, not the prior custom fixed-grid urine derivation. | Confirmed by user |
| SOFA-2 first-day total | Use `SUM(per-organ first-day maxima)`, not `MAX(hourly total)`. | Confirmed by user |
| SOFA-1 | Keep official MIMIC-derived SOFA-1 for hourly and first-day interfaces. | Confirmed by user |
| Sepsis definitions | Keep official absolute SOFA-1 sepsis, SOFA-1 delta sepsis, SOFA-2 delta sepsis, and selectable delta-union flags. Downstream studies choose the definition according to the research question. | Confirmed by user |
| Survival endpoints | `patient_outcomes` uses `mimiciv_team.survival_outcomes` as the local authoritative outcome source. The SOFA engineering layer must not recalculate survival endpoints from raw timestamps. | Confirmed by user |

## Why Survival Changed

The survival change is not a new scientific policy. It fixes an implementation omission.

Earlier project rules already established `mimiciv_team.survival_outcomes` as the governed local survival table. The prior `patient_outcomes` implementation still recalculated survival fields locally, which caused version drift. The candidate version now joins survival fields from `mimiciv_team.survival_outcomes`.

Affected fields include:

- `survival_days`
- `event_status`
- `icu_death_within_28_days`
- `icu_death_within_90_days`
- `mortality_1yr`

## Current-vs-Candidate Differences

| Comparison | Result | Interpretation |
| --- | --- | --- |
| SOFA-2 first-day current vs shadow | 0 differences | Candidate matches governed SOFA-2 first-day current logic. |
| SOFA-2 hourly current vs shadow | 0 differences | Candidate matches governed SOFA-2 hourly current logic. |
| SOFA-1 first-day integrity | 0 component-sum mismatches | Official SOFA-1 first-day total is internally consistent. |
| SOFA-1 hourly integrity | 0 component-sum mismatches | Official SOFA-1 hourly total is internally consistent. |
| Sepsis definition current vs shadow | 0 mismatches | SOFA-1 delta, SOFA-2 delta, and delta-union flags match shadow recomputation. |
| `patient_outcomes.sofa2_score` | 1,206 rows change | Expected stale-table fix: current `patient_outcomes` had not fully reflected the governed SOFA-2 first-day table. |
| `event_status` | 0 differences | Death/censor event indicator is unchanged. |
| `survival_days` | 67,828 differences among QA-clean rows | Mostly sub-day precision differences from using the governed survival table. |
| 28d/90d mortality | 763 differences each | 759 are QA rows with NULL governed statuses; 4 are same-day `dod` corrections. |
| 1-year mortality | 759 differences | All from QA rows with NULL governed statuses. |

## Survival QA Rows

`survival_qa_any_flag=1` marks survival data quality anomalies, not SOFA missingness.

Counts from `mimiciv_team.survival_outcomes`:

| QA issue | Count |
| --- | ---: |
| Any survival QA anomaly | 759 |
| `deathtime` later than hospital discharge time | 718 |
| Negative survival time | 34 |
| `dod` earlier than hospital discharge date | 13 |
| `dod` earlier than ICU admission date | 6 |
| `deathtime` without `dod` | 0 |
| `deathtime`/`dod` date mismatch | 0 |

Flags can overlap. The most common exact pattern is `qa_death_after_discharge=1` alone, with 716 rows.

For these 759 QA rows:

- `survival_days` is still populated.
- Windowed outcome fields such as `os_28d_status`, `os_90d_status`, `os_1yr_status`, and corresponding time fields are set to NULL.
- Downstream survival/mortality analyses should filter `survival_qa_any_flag=0` unless a project has a specific reason to inspect QA rows.

## Shadow Schema Size

Current shadow schema: `sofa_gov_20260619_rebuild_v1`.

Measured size:

| Scope | Size |
| --- | ---: |
| Full shadow schema | 16 GB |
| Table-like objects | 12 GB |
| Index objects | 3.7 GB |
| Core final audit artifacts only | 1.5 GB |
| Whole `mimiciv_31` database | 144 GB |

Recommendation: keep the full shadow schema through promotion and post-promotion validation. After validation and repository commit/push, decide whether to keep the full 16 GB schema, compress to core audit artifacts, or drop the shadow schema.

## Promotion Safety Gates

Completed gates:

- Shadow rebuild completed in `sofa_gov_20260619_rebuild_v1`.
- Shadow validation passed.
- Current-vs-shadow SOFA-2 first-day diff count was 0.
- External qoderclicn review second pass returned PASS.
- Promotion SQL refuses to run without the explicit approval token.
- Promotion SQL with a wrong approval token returns non-zero and does not run DDL.
- Post-promotion validation exists and does not pass before promotion.
- Promotion was executed after explicit user approval on 2026-06-19.
- Post-promotion validation completed successfully.
- Current views have 0 dependency edges to the shadow schema.
- Active governance manifest contains 7 current MIMIC interfaces.

## Promotion Result

The current production schema has been promoted.

Promoted current interfaces:

| Interface | Rows | Stays |
| --- | ---: | ---: |
| `mimiciv_derived.sofa1_hourly_current` | 8,219,121 | 94,437 |
| `mimiciv_derived.sofa2_hourly_current` | 8,373,089 | 94,458 |
| `mimiciv_derived.sofa1_first_day_current` | 94,458 | 94,458 |
| `mimiciv_derived.sofa2_first_day_current` | 94,458 | 94,458 |
| `mimiciv_derived.patient_outcomes` | 94,458 | 94,458 |
| `mimiciv_derived.sepsis3_definitions_current` | 94,458 | 94,458 |

Archived old current base tables:

- `mimiciv_derived_archive.patient_outcomes_pre_shadow_20260619`
- `mimiciv_derived_archive.sepsis3_definitions_current_pre_shadow_20260619`
- `mimiciv_derived_archive.sepsis3_sofa1_delta_pre_shadow_20260619`
- `mimiciv_derived_archive.sepsis3_sofa2_delta_pre_shadow_20260619`

A pre-existing archive table, `mimiciv_derived_archive.sepsis3_sofa2_delta`, was already present from 2026-06-17 and blocked the first promotion attempt because PostgreSQL could not move a current table into an archive schema where the same unversioned name already existed. It was preserved and renamed during the successful promotion to:

- `mimiciv_derived_archive.sepsis3_sofa2_delta_legacy_pre_shadow_promotion_20260619`

## Not Yet Done

No commit or push has been performed for this promotion state.

Shadow schema retention has not been decided. Current recommendation remains: keep full shadow until user inspection and repository commit/push are complete, then decide whether to retain the full 16 GB schema, retain only core audit artifacts, or drop it.
