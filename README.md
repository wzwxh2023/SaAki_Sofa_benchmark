# SaAki_Sofa_benchmark

Open-source SOFA-2 implementation and benchmark on **MIMIC-IV v3.1** for ICU sepsis mortality prediction.

> To our knowledge, this is the **first publicly available SOFA-2 SQL implementation on MIMIC-IV**.

---

## Background

SOFA-2 is the second-generation Sequential Organ Failure Assessment score (proposed in *JAMA *, 2025), refining the original SOFA (1996) with:

- Official MIMIC `urine_output_rate` based kidney urine scoring (6h / 12h / 24h)
- Platelet/bilirubin `lab48_rescue`: strict 24h evidence is used when present; 48h rescue is used only when strict 24h evidence is absent
- Virtual RRT Cr pathway (does not require urine)
- Refined cardiovascular scoring for vasoactive support
- Mechanical support (ECMO) recognition
- Brain/delirium component (sedation-aware)
- Explicit scoring rules for missing values

This repository provides:

1. A reproducible **PostgreSQL pipeline** that computes SOFA-2 (and SOFA-1 for reference) on MIMIC-IV v3.1
2. **Reviewer-response SQL queries** documenting sensitivity analyses for each methodology challenge raised during peer review
3. A documented **final SOFA-2 policy**: platelet/bilirubin `lab48_rescue` plus kidney scoring from the official MIMIC `urine_output_rate` derived table

---

## Publications

- **Letter** (all-ICU cohort, N = 65,366): *Journal of Intensive Care*. 2026;14:32. Full citation on the journal page.
- **Main article** (under revision at *Clinical Medicine*): Sepsis cohort, N = 30,667 post-patch; modeling cohort N = 29,246 (train/validation 20,597 / 8,649 by admission year 2168)

---

## Key Results (post-patch, 2026-04-03)

| Metric | SOFA-2 | SOFA-1 |
|---|---|---|
| ICU mortality AUC | **0.779** | 0.755 |
| Hospital mortality AUC | **0.745** | 0.725 |
| C-index, 7-day | **0.799** | 0.781 |
| C-index, 28-day | **0.751** | 0.736 |
| NRI (ICU) | **0.143** | reference |
| IDI (ICU) | **0.020** | reference |

SOFA-2 demonstrated **modestly but consistently better** predictive performance than SOFA-1 across mortality endpoints, at the cost of increased data requirements and implementation complexity.

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
├── 08_extract_outcomes_final_corrected.sql
├── 09_update_sepsis3_SOFA1.sql
└── archive/                  Historical patches, reviewer checks, and legacy validation SQL

run_steps.sh                  Shell driver running the current SQL pipeline sequentially
tests/                        Static guardrails for the current public SQL
utils/db_helper.py            Python helper for ad-hoc queries
LICENSE                       MIT
```

Only the numbered SQL files in `sofa2_sql/` are the current runnable pipeline.
Files under `sofa2_sql/archive/` are retained for audit/history and should not
be used as the primary implementation.

R analysis pipeline (Table 1, ROC/DCA, calibration, survival) is maintained locally and may be added in a future release.

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

3. Python 3.10+ with `psycopg2`, `sqlalchemy`, `pandas` (for `utils/db_helper.py` only)

### Run the pipeline

```bash
cd /path/to/SaAki_Sofa_benchmark
bash run_steps.sh
```

No credentials in scripts — `psql` auto-authenticates via `~/.pgpass`.

### Current SOFA-2 implementation

The current primary SQL policy is `lab48_rescue_kidney_uorate`.

For kidney scoring, the SQL uses the official MIMIC-IV derived table `mimiciv_derived.urine_output_rate` as the primary urine source. `02_stage_components.sql` stages hourly-aligned 6h/12h/24h rates from that table, and `03_hourly_raw_scores.sql` applies the SOFA-2 kidney rules. Absence of a urine-rate row is treated as missing urine-rate evidence, not as zero urine output.

For platelet and bilirubin, the SQL stages both strict current-hour evidence and 48h lookback candidates. `04_window_final_scores.sql` first computes rolling 24h strict evidence. The 48h candidate is used only when the corresponding rolling strict 24h window has no platelet/bilirubin evidence. The primary total remains exposed as `sofa2_total`, with explicit sensitivity columns:

- `sofa2_total_lab48_rescue`: primary/default policy
- `sofa2_total_strict24`: strict 24h platelet/bilirubin sensitivity
- `sofa2_total_full48_exploratory`: unconditional 48h platelet/bilirubin exploratory comparator

`sofa2_sql/archive/2026-06-18_legacy_kidney_patch/PATCH_kidney_three_rate.md` is retained as the historical record of the earlier fixed-grid three-window patch. The official `urine_output_rate` path supersedes that fixed-grid reconstruction for the main implementation.

---

## Citing

If you use this code, please cite the letter:

> *Journal of Intensive Care*. 2026;14:32 (full citation available on the journal landing page).

An expanded methodology article (sepsis cohort) is currently under revision.

---

## License

MIT — see [LICENSE](LICENSE).

---

## 中文摘要

本仓库提供在 MIMIC-IV v3.1 上实现 **SOFA-2**（JAMA  2025 提出的新版评分）的完整 PostgreSQL 管线，以及与 SOFA-1 在 ICU 脓毒症死亡率预测上的基准对比。**据我们所知，这是目前公开的第一份 SOFA-2 × MIMIC-IV SQL 实现**。

主要结论：SOFA-2 在 ICU 和院内死亡率预测上**一致但幅度有限地优于** SOFA-1（AUC 差异 0.02 左右；NRI = 0.143）。代价是计算复杂度上升（需要小时级 vasoactive 数据、platelet/bilirubin `lab48_rescue`、基于 MIMIC 官方 `urine_output_rate` 的三窗口尿量、ECMO/机械支持识别等）。

代码包含同行评审阶段（Reviewer #2 对 CV 评分 / dopamine 阈值 / 无尿处理 / 洗脱期等方法学质疑）的完整敏感性分析 SQL，可供后续研究者参考。
