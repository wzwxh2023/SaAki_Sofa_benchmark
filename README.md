# SaAki_Sofa_benchmark

Open-source SOFA-2 SQL implementation on **MIMIC-IV v3.1**.

> To our knowledge, this is the **first publicly available SOFA-2 SQL implementation on MIMIC-IV**.

---

## Background

SOFA-2 is the second-generation Sequential Organ Failure Assessment score,
introduced in 2025 as an update to the original SOFA score (1996). SOFA-2
defines organ-level scoring criteria; it does not prescribe one fixed SQL
mapping for any specific ICU database.

This repository is the MIMIC-IV v3.1 implementation layer. The following are
database-specific implementation choices in this SQL pipeline, not claims about
the wording of the SOFA-2 publication:

- Kidney urine scoring uses the official MIMIC `urine_output_rate` derived table for 6h / 12h / 24h urine-rate evidence
- Platelet/bilirubin use the `lab48_rescue` policy: strict 24h evidence is used when present; 48h rescue is used only when strict 24h evidence is absent
- Virtual RRT creatinine criteria are implemented separately from urine-output criteria
- Cardiovascular scoring maps MIMIC vasoactive support fields to SOFA-2 dose thresholds
- Mechanical support and ECMO sources are mapped from available MIMIC procedure and charted-event data
- Brain scoring includes the local sedation-aware GCS and delirium-medication logic used in this pipeline
- Missing-value handling is made explicit in SQL and documented through current and sensitivity score columns

This repository provides:

1. A reproducible **PostgreSQL pipeline** that computes SOFA-2 on MIMIC-IV v3.1 and can join an explicit SOFA-1 reference layer for cohort/outcome exports
2. **Audit and sensitivity SQL** documenting implementation decisions and alternative score policies
3. A documented **current governed SOFA-2 policy**: platelet/bilirubin `lab48_rescue` plus kidney scoring from the official MIMIC `urine_output_rate` derived table

This repository contains code and documentation only. It does not distribute
MIMIC-IV row-level data, derived patient-level exports, clinical notes, model
outputs, or manuscript-specific result files. Users must obtain their own
credentialed access to MIMIC-IV through PhysioNet before running the SQL.

---

## Repository Structure

```
sofa2_sql/                    Core PostgreSQL pipeline
├── 00_create_icustay_hourly_basedon_icuintime.sql
├── 01_setup_cleanup.sql
├── 02_stage_components.sql   Per-organ stage-1 tables (sedation, brain, resp,
│                             ecmo/mech, oxygen, kidney labs, rrt, urine, coag, liver)
├── 03_hourly_raw_scores.sql  Hourly raw organ scores
├── 04_window_final_scores.sql
├── 05_filter_hr_nonnegative.sql
├── 06_first_day_sofa2_simple.sql
├── 07_sepsis3_sofa2_delta.sql
├── 08_sepsis3_sofa1_delta.sql
└── 09_extract_outcomes_final_corrected.sql

run_steps.sh                  Shell driver running the current SQL pipeline sequentially
tests/                        Static guardrails for the current public SQL
LICENSE                       MIT
```

Only the numbered SQL files in `sofa2_sql/` are the current runnable pipeline.

Manuscript-specific analysis scripts, cohort flowcharts, model outputs, and
performance estimates are intentionally kept outside this repository. This
repository is the reusable score-construction layer.

---

## Reproducibility

### Prerequisites

1. PostgreSQL 14+ with MIMIC-IV v3.1 loaded
   - Requires [PhysioNet credentialed access](https://physionet.org/content/mimiciv/3.1/) and DUA approval
   - `mimiciv_derived` schema should be populated via the official [MIT-LCP/mimic-code](https://github.com/MIT-LCP/mimic-code) concepts scripts

2. `~/.pgpass` configured for authentication (mode 0600):
   ```
   <host>:<port>:*:<user>:<password>
   ```

### Run the pipeline

```bash
cd /path/to/SaAki_Sofa_benchmark
export DB_HOST=localhost
export DB_USER=postgres
export DB_NAME=mimiciv
bash run_steps.sh
```

No credentials in scripts — `psql` auto-authenticates via `~/.pgpass`.

Steps `00`-`07` build the SOFA-2 hourly, first-day, and SOFA-2 delta
artifacts from MIMIC-IV derived tables. Steps `08`-`09` additionally require a
local SOFA-1 governance layer:

- `mimiciv_derived.sofa1_hourly_current`
- `mimiciv_derived.sofa_first_day_current`

In the current governed database used by this project, those views expose the
official MIMIC SOFA-1 implementation. If these views are absent, install or
create the SOFA-1 reference layer before running the cohort/outcome export
steps.

### Current SOFA-2 implementation

The current primary SQL policy is `lab48_rescue_kidney_uorate`.

For kidney scoring, the SQL uses the official MIMIC-IV derived table `mimiciv_derived.urine_output_rate` as the primary urine source. `02_stage_components.sql` stages hourly-aligned 6h/12h/24h rates from that table, and `03_hourly_raw_scores.sql` applies the SOFA-2 kidney rules. Absence of a urine-rate row is treated as missing urine-rate evidence, not as zero urine output.

For platelet and bilirubin, the SQL stages both strict current-hour evidence and 48h lookback candidates. `04_window_final_scores.sql` first computes rolling 24h strict evidence. The 48h candidate is used only when the corresponding rolling strict 24h window has no platelet/bilirubin evidence. The primary total remains exposed as `sofa2_total`, with explicit sensitivity columns:

- `sofa2_total_lab48_rescue`: primary/default policy
- `sofa2_total_strict24`: strict 24h platelet/bilirubin sensitivity
- `sofa2_total_full48_exploratory`: unconditional 48h platelet/bilirubin exploratory comparator

### Sepsis definition governance

This repository exposes explicit Sepsis-3 cohort flags rather than enforcing one
universal cohort definition. Downstream studies should choose the definition
that matches the research question, for example a SOFA-1 delta-defined cohort, a
SOFA-2 delta-defined cohort, the official MIMIC comparator, or a union cohort.

The delta-union flag is retained as one available option. The column name
contains `primary` for backward compatibility with earlier local analyses; it
should be read as a selectable union cohort flag, not as a universal default
for every downstream study.

```text
sepsis3_primary_delta_any = sepsis3_sofa1_delta OR sepsis3_sofa2_delta
```

`mimiciv_derived.sepsis3` is retained as the official MIMIC comparator
(`sepsis3_sofa1_official_absolute`: SOFA-1 >= 2 with baseline assumed 0).
`09_extract_outcomes_final_corrected.sql` first materializes
`mimiciv_derived.sepsis3_definitions_current` and then exports the same
definitions into `mimiciv_derived.patient_outcomes` with explicit names:

- `sepsis3_sofa1_official_absolute`
- `sepsis3_sofa1_delta`
- `sepsis3_sofa2_delta`
- `sepsis3_primary_delta_any`
- `sepsis3_primary_policy`

Current MIMIC-IV score-source policy:

| Score layer | Current source/policy | Notes |
| --- | --- | --- |
| SOFA-1 | official MIMIC implementation exposed through the local SOFA-1 current views | Used as comparator and for SOFA-1 delta cohorts |
| SOFA-2 | local SOFA-2 SQL with platelet/bilirubin `lab48_rescue` and kidney `urine_output_rate` | Main SOFA-2 implementation in this repository |

---

## Citing

If you use this code, cite this repository and the relevant SOFA/SOFA-2
methodology papers. Article-specific cohort sizes and model performance should
be reported from the analysis repository or manuscript that used this score
pipeline, not from this infrastructure repository.

Related validation studies may cite their own cohort definitions, score-policy
versions, endpoints, and statistical outputs separately.

Related publication using this implementation:

> Lin L, Fu Z, Sun H, Wang Y, Zhang S, Bai S, Wen X.
> Comparative prognostic performance of SOFA-1 and SOFA-2 in patients with
> sepsis at ICU admission. *Clinical Medicine*. 2026;26(4):100601.
> doi: [10.1016/j.clinme.2026.100601](https://doi.org/10.1016/j.clinme.2026.100601).

---

## License

MIT — see [LICENSE](LICENSE).

---

## 中文摘要

本仓库提供在 MIMIC-IV v3.1 上实现 **SOFA-2**（JAMA 2025 提出的新版评分）的完整 PostgreSQL 管线。**据我们所知，这是目前公开的第一份 SOFA-2 × MIMIC-IV SQL 实现**。

本仓库定位为可复用的评分构建基础工程，代码包含 SOFA-2 组件构建、版本治理和敏感性分析 SQL，可供后续研究者复现或审查评分实现。仓库不包含 MIMIC-IV 行级数据、临床文本或论文结果导出文件。
