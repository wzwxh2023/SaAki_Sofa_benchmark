# SOFA-2 升级文档

## 概述
本文档记录了对 `sofa2.sql` 进行的升级，以实现完整的SOFA-2评分功能，基于 `00_helper_views.sql` 中定义的完整实现。

## 文件变更记录

### 原始文件
- **备份文件**: `sofa2_original_backup.sql`
- **升级文件**: `sofa2.sql` (当前版本)

### 升级日期
- **执行日期**: 2025-11-15
- **优化日期**: 2025-11-15 (谵妄药物优化)
- **基于标准**: Ranzani OT, et al. JAMA 2025 (SOFA-2)
- **临床确认**: 基于专家确认的5种核心谵妄治疗药物

## 升级内容对比

### 0. 谵妄药物检测优化 (Delirium Medications Optimization)

#### 原始版本 (sofa2.sql:57-64)
```sql
-- 包含8种谵妄药物（包括商品名）
WHERE (LOWER(pr.drug) LIKE '%haloperidol%'
       OR LOWER(pr.drug) LIKE '%quetiapine%'
       OR LOWER(pr.drug) LIKE '%olanzapine%'
       OR LOWER(pr.drug) LIKE '%risperidone%'
       OR LOWER(pr.drug) LIKE '%haldol%'
       OR LOWER(pr.drug) LIKE '%seroquel%'
       OR LOWER(pr.drug) LIKE '%zyprexa%'
       OR LOWER(pr.drug) LIKE '%risperdal%')
```

#### 最终版本 (基于临床确认)
```sql
-- 5种核心谵妄治疗抗精神病药物
WHERE (LOWER(pr.drug) LIKE '%haloperidol%'
       OR LOWER(pr.drug) LIKE '%quetiapine%'
       OR LOWER(pr.drug) LIKE '%olanzapine%'
       OR LOWER(pr.drug) LIKE '%risperidone%'
       OR LOWER(pr.drug) LIKE '%ziprasidone%')
       -- Note: Including only core delirium treatment medications based on clinical evidence
       -- Dexmedetomidine excluded as it's primarily a sedation agent
```

**核心药物** (基于临床确认):
- ✅ **Haloperidol** - 第一代抗精神病药物，谵妄治疗金标准
- ✅ **Quetiapine** - 第二代抗精神病药物
- ✅ **Olanzapine** - 第二代抗精神病药物
- ✅ **Risperidone** - 第二代抗精神病药物
- ✅ **Ziprasidone** - 第二代抗精神病药物

**优化重点**:
- ✅ **简化检测逻辑**: 移除冗余的商品名匹配
- ✅ **临床导向**: 专注于5种核心谵妄治疗药物
- ✅ **排除干扰**: 明确排除镇静药物如dexmedetomidine
- ✅ **提高准确性**: 基于临床证据而非数据库可用性

### 1. 机械循环支持检测 (Mechanical Circulatory Support)

#### 原始版本 (sofa2.sql:89-101)
```sql
-- 仅检测ECMO和IABP
, mechanical_support AS (
    SELECT DISTINCT
        stay_id,
        charttime,
        CASE
            WHEN itemid IN (228001, 229270, 229272) THEN 'ECMO'
            WHEN itemid IN (228000, 224797, 224798) THEN 'IABP'
            ELSE 'Other'
        END AS device_type,
        1 AS has_mechanical_support
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (228001, 229270, 229272, 228000, 224797, 224798)
)
```

#### 升级版本
```sql
-- 完整检测ECMO, IABP, LVAD, Impella
, mechanical_support AS (
    SELECT DISTINCT
        stay_id,
        charttime,
        CASE
            WHEN itemid IN (228001, 229270, 229272) THEN 'ECMO'
            WHEN itemid IN (228000, 224797, 224798) THEN 'IABP'
            WHEN itemid IN (224828, 224829) THEN 'Impella'
            WHEN LOWER(ce.value) LIKE '%lvad%' THEN 'LVAD'
            WHEN LOWER(ce.value) LIKE '%ecmo%' THEN 'ECMO'
            WHEN LOWER(ce.value) LIKE '%iabp%' THEN 'IABP'
            WHEN LOWER(ce.value) LIKE '%impella%' THEN 'Impella'
        END AS device_type,
        1 AS has_mechanical_support
    FROM mimiciv_icu.chartevents ce
    WHERE itemid IN (228001, 229270, 229272, 228000, 224797, 224798, 224828, 224829)
       OR (itemid IN (
               SELECT itemid FROM mimiciv_icu.d_items
               WHERE LOWER(label) LIKE '%ecmo%'
                  OR LOWER(label) LIKE '%iabp%'
                  OR LOWER(label) LIKE '%impella%'
                  OR LOWER(label) LIKE '%lvad%'
           ) AND value IS NOT NULL)
)
```

**新增功能**:
- ✅ LVAD检测
- ✅ Impella检测 (224828, 224829)
- ✅ 基于value字段的文本匹配
- ✅ 基于d_items表的设备标签匹配

### GCS评分逻辑优化

#### 原始版本 (sofa2.sql:577)
```sql
-- GCS 13-14 OR on delirium meds = 1
WHEN (gcs_min >= 13 AND gcs_min <= 14) OR on_delirium_med = 1 THEN 1
```

#### 升级版本 (sofa2.sql:581-582)
```sql
-- GCS 13-14 OR on delirium meds = 1
-- Note: Any patient on delirium medications gets minimum 1 point regardless of GCS
WHEN (gcs_min >= 13 AND gcs_min <= 14) OR COALESCE(on_delirium_med, 0) = 1 THEN 1
```

**优化内容**:
- ✅ 更明确的注释说明谵妄药物患者的评分逻辑
- ✅ 使用 `COALESCE(on_delirium_med, 0) = 1` 确保NULL值处理正确
- ✅ 添加说明：任何使用谵妄药物的患者最少得1分

**临床意义**: 确保使用谵妄治疗药物的患者，即使GCS评分正常(15分)，也会因为药物影响而获得至少1分的脑部评分。

### 2. RRT代谢标准检测 (RRT Metabolic Criteria)

#### 原始版本
- ❌ **缺失**: 仅检测实际RRT状态，未实现代谢标准

#### 升级版本 (新增CTE)
```sql
-- RRT代谢标准检测
, rrt_metabolic_criteria AS (
    SELECT
        co.stay_id,
        co.hr,
        cr.creatinine_max,
        k.potassium_max,
        bg.ph_min,
        bg.bicarbonate_min,
        CASE
            WHEN cr.creatinine_max > 1.2
                 AND (k.potassium_max >= 6.0
                      OR (bg.ph_min <= 7.2 AND bg.bicarbonate_min <= 12))
            THEN 1
            ELSE 0
        END AS meets_rrt_criteria
    FROM co
    LEFT JOIN (
        SELECT stay_id, charttime, MAX(creatinine) AS creatinine_max
        FROM mimiciv_derived.chemistry
        GROUP BY stay_id, charttime
    ) cr ON co.stay_id = cr.stay_id
        AND co.starttime < cr.charttime
        AND co.endtime >= cr.charttime
    LEFT JOIN (
        SELECT stay_id, charttime, MAX(potassium) AS potassium_max
        FROM mimiciv_derived.chemistry
        GROUP BY stay_id, charttime
    ) k ON co.stay_id = k.stay_id
        AND co.starttime < k.charttime
        AND co.endtime >= k.charttime
    LEFT JOIN (
        SELECT stay_id, charttime, MIN(ph) AS ph_min, MIN(bicarbonate) AS bicarbonate_min
        FROM mimiciv_derived.bg
        WHERE specimen = 'ART.'
        GROUP BY stay_id, charttime
    ) bg ON co.stay_id = bg.stay_id
        AND co.starttime < bg.charttime
        AND co.endtime >= bg.charttime
)
```

**新增功能**:
- ✅ 肌酐 >1.2 mg/dL 检测
- ✅ 钾 ≥6.0 mmol/L 检测
- ✅ 代谢性酸中毒检测 (pH ≤7.2 且碳酸氢盐 ≤12 mmol/L)
- ✅ 逻辑组合判断

### 3. 额外血管活性药物检测

#### 原始版本 (sofa2.sql:227)
```sql
-- TODO: Add vasopressin and phenylephrine if needed
```

#### 升级版本 (新增CTE)
```sql
-- 血管活性药物检测
, vasopressin AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(vas.rate) AS vasopressin_rate
    FROM co
    LEFT JOIN mimiciv_icu.inputevents vas
        ON co.stay_id = vas.stay_id
        AND co.endtime > vas.starttime
        AND co.endtime <= vas.endtime
    WHERE vas.itemid = 222315  -- Vasopressin
      AND vas.rate IS NOT NULL
      AND vas.rate > 0
    GROUP BY co.stay_id, co.hr
)

, phenylephrine AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(vas.rate / COALESCE(wt.weight, 80)) AS phenylephrine_rate
    FROM co
    LEFT JOIN patient_weight wt
        ON co.stay_id = wt.stay_id
    LEFT JOIN mimiciv_icu.inputevents vas
        ON co.stay_id = vas.stay_id
        AND co.endtime > vas.starttime
        AND co.endtime <= vas.endtime
    WHERE vas.itemid = 221749  -- Phenylephrine
      AND vas.rate IS NOT NULL
      AND vas.rate > 0
    GROUP BY co.stay_id, co.hr
)
```

**新增功能**:
- ✅ Vasopressin (加压素) 检测 (itemid: 222315)
- ✅ Phenylephrine (去氧肾上腺素) 检测 (itemid: 221749)
- ✅ 基于体重的剂量计算

### 4. 多时间窗尿量计算

#### 原始版本 (sofa2.sql:309-326)
```sql
-- 仅计算24小时窗口
, uo_weight AS (
    SELECT co.stay_id, co.hr
        -- Calculate weight-based urine output over 24h window
        , MAX(
            CASE WHEN uo.uo_tm_24hr >= 22 AND uo.uo_tm_24hr <= 30
                THEN uo.urineoutput_24hr / COALESCE(wt.weight, 80) / 24  -- ml/kg/h
            END) AS uo_ml_kg_h_24hr
        -- For shorter windows, we'll approximate from 24h rate
        -- Ideally should calculate 6h, 12h windows separately
    FROM co
    LEFT JOIN patient_weight wt
        ON co.stay_id = wt.stay_id
    LEFT JOIN mimiciv_derived.urine_output_rate uo
        ON co.stay_id = uo.stay_id
            AND co.starttime < uo.charttime
            AND co.endtime >= uo.charttime
    GROUP BY co.stay_id, co.hr
)
```

#### 升级版本
```sql
-- 多时间窗尿量计算
, uo_data AS (
    SELECT
        co.stay_id,
        co.hr,
        uo.urineoutput,
        wt.weight,
        uo.charttime
    FROM co
    LEFT JOIN patient_weight wt
        ON co.stay_id = wt.stay_id
    LEFT JOIN mimiciv_derived.urine_output uo
        ON co.stay_id = uo.stay_id
        AND co.starttime < uo.charttime
        AND co.endtime >= uo.charttime
    WHERE wt.weight IS NOT NULL AND wt.weight > 0
)

, uo_weight_based AS (
    SELECT
        stay_id,
        hr,
        weight,
        -- 6-hour window
        SUM(urineoutput) OVER (
            PARTITION BY stay_id
            ORDER BY charttime
            RANGE BETWEEN INTERVAL '6' HOUR PRECEDING AND CURRENT ROW
        ) / (weight * 6) AS uo_ml_kg_h_6h,
        -- 12-hour window
        SUM(urineoutput) OVER (
            PARTITION BY stay_id
            ORDER BY charttime
            RANGE BETWEEN INTERVAL '12' HOUR PRECEDING AND CURRENT ROW
        ) / (weight * 12) AS uo_ml_kg_h_12h,
        -- 24-hour window
        SUM(urineoutput) OVER (
            PARTITION BY stay_id
            ORDER BY charttime
            RANGE BETWEEN INTERVAL '24' HOUR PRECEDING AND CURRENT ROW
        ) / (weight * 24) AS uo_ml_kg_h_24h
    FROM uo_data
)
```

**新增功能**:
- ✅ 6小时滑动窗口尿量计算
- ✅ 12小时滑动窗口尿量计算
- ✅ 24小时滑动窗口尿量计算
- ✅ 精确的时间对齐计算

### 5. CPAP/BiPAP检测

#### 原始版本
- ❌ **缺失**: 未单独检测CPAP/BiPAP

#### 升级版本 (新增CTE)
```sql
-- CPAP/BiPAP检测
, cpap_bipap AS (
    SELECT
        stay_id,
        charttime AS starttime,
        charttime AS endtime,
        CASE
            WHEN itemid = 227287 THEN 'CPAP'
            WHEN itemid = 227288 THEN 'BiPAP'
        END AS support_type,
        1 AS has_cpap_bipap
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (227287, 227288)
      AND value IS NOT NULL
)
```

**新增功能**:
- ✅ CPAP检测 (itemid: 227287)
- ✅ BiPAP检测 (itemid: 227288)
- ✅ 与高级呼吸支持整合

## 心血管评分升级

### 原始版本 (sofa2.sql:465-496)
- 未考虑额外血管活性药物

### 升级版本
```sql
-- 心血管评分包含vasopressin和phenylephrine
, CASE
    -- 4 points: Mechanical circulatory support
    WHEN has_mechanical_support = 1 THEN 4
    -- Calculate combined NE+Epi dose
    WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.4 THEN 4
    -- 4 points: Medium dose NE+Epi + other vasopressor
    WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
         AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4
         AND (COALESCE(rate_dopamine, 0) > 0 OR COALESCE(rate_dobutamine, 0) > 0
              OR COALESCE(vasopressin_rate, 0) > 0 OR COALESCE(phenylephrine_rate, 0) > 0)
        THEN 4
    -- 3 points: Medium dose NE+Epi (0.2-0.4)
    WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0.2
         AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.4
        THEN 3
    -- 3 points: Low dose NE+Epi + other vasopressor
    WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
         AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2
         AND (COALESCE(rate_dopamine, 0) > 0 OR COALESCE(rate_dobutamine, 0) > 0
              OR COALESCE(vasopressin_rate, 0) > 0 OR COALESCE(phenylephrine_rate, 0) > 0)
        THEN 3
    -- 2 points: Low dose NE+Epi OR any other vasopressor
    WHEN (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) > 0
         AND (COALESCE(rate_norepinephrine, 0) + COALESCE(rate_epinephrine, 0)) <= 0.2
        THEN 2
    -- 2 points: Any other vasopressor
    WHEN COALESCE(rate_dopamine, 0) > 0 OR COALESCE(rate_dobutamine, 0) > 0
         OR COALESCE(vasopressin_rate, 0) > 0 OR COALESCE(phenylephrine_rate, 0) > 0 THEN 2
    -- 1 point: MAP <70 without vasopressors
    WHEN mbp_min < 70 THEN 1
    ELSE 0
END AS cardiovascular
```

## 肾脏评分升级

### 原始版本
- 仅考虑实际RRT状态

### 升级版本
```sql
-- 肾脏评分包含RRT代谢标准
, CASE
    -- 4 points: On RRT
    WHEN on_rrt = 1 THEN 4
    -- 4 points: Meets RRT criteria (Cr >1.2 AND (K ≥6.0 OR metabolic acidosis))
    WHEN meets_rrt_criteria = 1 THEN 4
    -- 3 points: Cr >3.5 OR severe oliguria/anuria
    WHEN creatinine_max > 3.5 THEN 3
    WHEN uo_ml_kg_h_6h < 0.3 THEN 3  -- 6h window
    -- 2 points: Cr ≤3.5 but >2.0 OR moderate oliguria
    WHEN creatinine_max > 2.0 AND creatinine_max <= 3.5 THEN 2
    WHEN uo_ml_kg_h_12h >= 0.3 AND uo_ml_kg_h_12h < 0.5 THEN 2  -- 12h window
    -- 1 point: Cr ≤2.0 but >1.2 OR mild oliguria
    WHEN creatinine_max > 1.2 AND creatinine_max <= 2.0 THEN 1
    WHEN uo_ml_kg_h_24h >= 0.3 AND uo_ml_kg_h_24h < 0.5 THEN 1  -- 24h window
    ELSE 0
END AS kidney
```

## 呼吸评分升级

### 升级版本
```sql
-- 呼吸评分包含CPAP/BiPAP
, CASE
    -- 4 points: PF ≤75 with advanced support OR ECMO
    WHEN on_ecmo = 1 THEN 4
    WHEN pf_vent_min <= 75 AND has_advanced_support = 1 THEN 4
    -- 3 points: PF ≤150 with advanced support
    WHEN pf_vent_min <= 150 AND has_advanced_support = 1 THEN 3
    -- 2 points: PF ≤225
    WHEN pf_novent_min <= 225 THEN 2
    WHEN pf_vent_min <= 225 THEN 2
    -- 1 point: PF ≤300
    WHEN pf_novent_min <= 300 THEN 1
    WHEN pf_vent_min <= 300 THEN 1
    -- 0 points: PF >300
    WHEN COALESCE(pf_vent_min, pf_novent_min) IS NULL THEN NULL
    ELSE 0
END AS respiratory
```

## 数据库表依赖

新增依赖表：
- `mimiciv_icu.d_items` (用于设备标签匹配)
- `mimiciv_icu.inputevents` (血管活性药物)

## 性能影响

### 潜在性能优化点
1. **RRT代谢标准查询** - 可能需要优化复杂的子查询
2. **多时间窗尿量计算** - 窗口函数可能影响性能
3. **设备检测增强** - 增加了更多itemid和文本匹配

### 建议优化措施
1. 考虑为频繁查询的列创建索引
2. 可以将复杂CTE物化以提高性能
3. 在生产环境中测试查询执行计划

## 验证建议

### 数据验证
1. 验证新增设备检测的实际数据存在性
2. 检查血管活性药物的剂量单位一致性
3. 确认RRT代谢标准的逻辑正确性

### 临床验证
1. 与原始SOFA-2论文对比评分逻辑
2. 检查新增功能的临床合理性
3. 评估对脓毒症检出率的影响

## 版本兼容性

- **数据库**: PostgreSQL (MIMIC-IV)
- **兼容性**: BigQuery需要调整日期时间函数语法
- **MIMIC版本**: v2.2 / v1.0

## 维护说明

1. **定期检查**: MIMIC数据库更新可能影响itemid
2. **参数调整**: 阈值参数可能需要根据本地数据调整
3. **性能监控**: 监控查询执行时间，必要时优化

### 测试文件
- **测试脚本**: `test_delirium_meds.sql` (谵妄药物检测测试)
- **验证脚本**: `validate_upgrade.sh` (整体升级验证)

---
**升级完成日期**: 2025-11-15
**优化日期**: 2025-11-15 (谵妄药物优化)
**升级人员**: AI Assistant
**版本**: v2.2 (完整SOFA-2实现 + 优化谵妄药物检测)
**临床确认**: 基于5种核心抗精神病药物的谵妄治疗