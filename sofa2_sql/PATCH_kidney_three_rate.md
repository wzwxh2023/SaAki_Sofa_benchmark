# MIMIC-IV SOFA-2 肾脏评分修正补丁

> 日期: 2026-04-03
> 来源: eICU SOFA-2 项目 Codex Gate 1 审查后对齐的修正
> 同步修改: eICU 已改完，本文件指导 MIMIC-IV 同步

## 修改原因

1. **尿量单一最长窗口被稀释**: 原代码只存一个 `urine_rate_ml_kg_h`（取最长可用窗口），住院多天的患者如果近期才开始少尿，长窗口均值正常会掩盖短窗口异常
2. **Score 2 在 hr≥24 失效**: `time_window_status IN ('full_12h','full_6h')` 不包含 `'full_24h'`，导致 24h+ 患者 0.3-0.5 区间的少尿漏评
3. **Virtual RRT Cr 路径多了不必要的尿量窗口要求**: 原文只要求 Cr>1.2 + 代谢指标，不需要尿量数据
4. **无尿定义从 <5mL 改为 =0mL**: 与 SOFA-2 原文一致

## 涉及文件（只改 2 个）

- `02_stage_components.sql` — 尿量中间表输出列
- `03_hourly_raw_scores.sql` — 肾脏评分逻辑

## 修改后必须重跑的全流程

```bash
# 按顺序执行（02 改了中间表，下游全部依赖）
psql ... -f 02_stage_components.sql
psql ... -f 03_hourly_raw_scores.sql
psql ... -f 04_window_final_scores.sql
psql ... -f 05_filter_hr_nonnegative.sql
psql ... -f 06_first_day_sofa2_simple.sql
psql ... -f 07_sepsis3_sofa2_delta.sql
psql ... -f 08_extract_outcomes_final_corrected.sql
psql ... -f 09_update_sepsis3_SOFA1.sql   # 代码不改，但中间表重建了要重跑
```

---

## 修改 1/2: `02_stage_components.sql`

### 定位: 尿量中间表 `sofa2_stage1_urine` 的输出列（约第 505-523 行）

### 删除:

```sql
    -- **修复：根据实际可用时间计算尿量速率**
    CASE
        WHEN g.hr >= 0 AND w.weight > 0 THEN
            CASE
                WHEN g.hr >= 24 THEN SUM(uo_vol_hourly) OVER w24 / w.weight / 24  -- 有完整24小时数据
                WHEN g.hr >= 12 THEN SUM(uo_vol_hourly) OVER w12 / w.weight / 12  -- 有12小时数据
                WHEN g.hr >= 6 THEN SUM(uo_vol_hourly) OVER w6 / w.weight / 6    -- 有6小时数据
                ELSE NULL  -- 前6小时数据不足，不评估尿量速率
            END
        ELSE NULL
    END AS urine_rate_ml_kg_h,

    -- **标记数据是否足够进行评分**
    CASE
        WHEN g.hr >= 24 THEN 'full_24h'
        WHEN g.hr >= 12 THEN 'full_12h'
        WHEN g.hr >= 6 THEN 'full_6h'
        ELSE 'insufficient'
    END AS time_window_status
```

### 替换为:

```sql
    -- 三窗口尿量速率 (ml/kg/h): 同时输出，评分时级联判断
    -- 修正: 原 urine_rate_ml_kg_h 只存最长窗口，长期患者近期少尿被稀释
    CASE WHEN g.hr >= 6  AND w.weight > 0
         THEN SUM(uo_vol_hourly) OVER w6  / w.weight / 6
    END AS rate_6h,

    CASE WHEN g.hr >= 12 AND w.weight > 0
         THEN SUM(uo_vol_hourly) OVER w12 / w.weight / 12
    END AS rate_12h,

    CASE WHEN g.hr >= 24 AND w.weight > 0
         THEN SUM(uo_vol_hourly) OVER w24 / w.weight / 24
    END AS rate_24h
```

### 不动的部分

`uo_sum_6h`, `uo_sum_12h`, `uo_sum_24h`, `cnt_6h`, `cnt_12h`, `cnt_24h`, WINDOW 定义 — 全部保留不变。

---

## 修改 2/2: `03_hourly_raw_scores.sql`

### 定位: `kidney_sofa` CTE（约第 190-234 行）

### 删除:

```sql
kidney_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        l.creatinine,
        l.potassium,
        l.ph,
        l.bicarbonate,
        r.on_rrt,
        u.weight,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,
        u.cnt_6h,
        u.cnt_12h,
        u.cnt_24h,
        u.urine_rate_ml_kg_h,        -- **新增：修复后的尿量速率**
        u.time_window_status,        -- **新增：时间窗口状态**
        CASE
            -- Score 4: RRT或Virtual RRT（需要足够数据进行评估）
            WHEN r.on_rrt = 1 THEN 4
            WHEN (l.creatinine > 1.2 OR u.urine_rate_ml_kg_h < 0.3)
                 AND (l.potassium >= 6.0 OR (l.ph <= 7.2 AND l.bicarbonate <= 12))
                 AND u.time_window_status IN ('full_24h', 'full_12h', 'full_6h') THEN 4

            -- Score 3: 严重肾功能不全
            WHEN l.creatinine > 3.5 THEN 3
            WHEN u.urine_rate_ml_kg_h < 0.3 AND u.time_window_status IN ('full_24h', 'full_12h') THEN 3
            WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3

            -- Score 2: 中度肾功能不全
            WHEN l.creatinine > 2.0 THEN 2
            WHEN u.urine_rate_ml_kg_h < 0.5 AND u.time_window_status IN ('full_12h', 'full_6h') THEN 2

            -- Score 1: 轻度肾功能不全
            WHEN l.creatinine > 1.2 THEN 1
            WHEN u.urine_rate_ml_kg_h < 0.5 AND u.time_window_status = 'full_6h' THEN 1

            ELSE 0
        END AS kidney_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs l ON co.stay_id = l.stay_id AND co.hr = l.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt r ON co.stay_id = r.stay_id AND co.hr = r.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON co.stay_id = u.stay_id AND co.hr = u.hr
)
```

### 替换为:

```sql
kidney_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- ========== Score 4: RRT 或 Virtual RRT ==========
            WHEN r.on_rrt = 1 THEN 4
            -- Virtual RRT 路径1: Cr 驱动（不要求尿量窗口）
            WHEN l.creatinine > 1.2
                 AND (l.potassium >= 6.0 OR (l.ph <= 7.2 AND l.bicarbonate <= 12)) THEN 4
            -- Virtual RRT 路径2: 少尿驱动
            WHEN COALESCE(u.rate_6h, u.rate_12h, u.rate_24h) < 0.3
                 AND (l.potassium >= 6.0 OR (l.ph <= 7.2 AND l.bicarbonate <= 12)) THEN 4

            -- ========== Score 3: 严重肾功能不全 ==========
            WHEN l.creatinine > 3.5 THEN 3
            -- 24h 窗口极少尿
            WHEN u.rate_24h < 0.3 THEN 3
            -- 12h 无尿（严格 0 mL）
            WHEN u.uo_sum_12h = 0 AND u.cnt_12h >= 12 THEN 3

            -- ========== Score 2: 中度 ==========
            WHEN l.creatinine > 2.0 THEN 2
            -- 12h 窗口少尿（优先查长窗口）
            WHEN u.rate_12h < 0.5 THEN 2

            -- ========== Score 1: 轻度 ==========
            WHEN l.creatinine > 1.2 THEN 1
            -- 6h 窗口少尿（短窗口兜底：刚来的或近期恶化的）
            WHEN u.rate_6h < 0.5 THEN 1

            ELSE 0
        END AS kidney_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs l ON co.stay_id = l.stay_id AND co.hr = l.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt r ON co.stay_id = r.stay_id AND co.hr = r.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON co.stay_id = u.stay_id AND co.hr = u.hr
)
```

---

## 改动逐条对照

| 项目 | 旧代码 | 新代码 | 原因 |
|------|--------|--------|------|
| 尿量输出列 | `urine_rate_ml_kg_h`（单一最长窗口）+ `time_window_status` | `rate_6h` / `rate_12h` / `rate_24h`（三列同时输出） | 长窗口稀释近期少尿 |
| Virtual RRT | 单条 `(Cr>1.2 OR rate<0.3) AND 代谢 AND 尿量窗口` | 拆两路径: Cr 路径不要求尿量窗口 | Cr 路径被尿量窗口误拦 |
| 无尿 ≥12h | `uo_sum_12h < 5.0` | `uo_sum_12h = 0` | SOFA-2 原文要求 0 mL |
| Score 3 UO | `rate < 0.3 AND status IN ('full_24h','full_12h')` | `rate_24h < 0.3` | 简化，24h 窗口直接用 |
| Score 2 UO | `rate < 0.5 AND status IN ('full_12h','full_6h')` | `rate_12h < 0.5` | 修复 hr≥24 时失效 |
| Score 1 UO | `rate < 0.5 AND status = 'full_6h'` | `rate_6h < 0.5` | 兜底近期恶化 |

## 验证方法

重跑后对比:
1. **SOFA-1 分数应完全不变**（回归验证锚点）
2. **SOFA-2 kidney score 分布会变**: 预期 score 1/2 在 hr≥24 的患者中增加
3. **SOFA-2 总分**: 预期轻微上升（更多肾脏分被捕获）
