# SOFA-2 实现总结（MIMIC-IV版）

**创建日期**: 2025-11-14
**状态**: ✅ 完成 SQL 实现
**下一步**: 执行并验证

---

## 📋 项目概览

### 目标
为 SA-AKI Letter 研究项目实现 SOFA-2 评分系统（基于 JAMA 2025 发表的最新标准），用于与 SOFA-1 进行对比分析。

### 完成内容
✅ **6 个 SQL 文件** 已创建:
1. `00_helper_views.sql` - 辅助视图和 CTE 模板
2. `sofa2.sql` - 每小时 SOFA-2 计算
3. `first_day_sofa2.sql` - 首日 SOFA-2 计算
4. `sepsis3_sofa2.sql` - 基于 SOFA-2 的 Sepsis-3 识别
5. `validation/compare_sofa1_sofa2.sql` - SOFA-1 vs SOFA-2 对比分析
6. `README.md` - 完整使用文档

---

## 🔑 SOFA-2 vs SOFA-1 关键变化

### 1. Brain/Neurological（神经系统）
**变化**: 新增谵妄药物考虑

| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| **0分** | GCS 15 | GCS 15 且无谵妄药物 |
| **1分** | GCS 13-14 | GCS 13-14 **或** 使用谵妄药物* |
| **2分** | GCS 10-12 | GCS 9-12 |
| **3分** | GCS 6-9 | GCS 6-8 |
| **4分** | GCS <6 | GCS 3-5 |

*谵妄药物: Haloperidol, Quetiapine, Olanzapine, Risperidone

**实现关键点**:
- 从 `prescriptions` 表提取谵妄药物
- 检查首日是否使用

---

### 2. Respiratory（呼吸系统）⭐ 重大更新

| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| **0分** | PF >400 | PF >300 |
| **1分** | PF ≤400 | PF ≤300 |
| **2分** | PF <300 | PF ≤225 |
| **3分** | PF <200 (有创通气) | PF ≤150 + **高级呼吸支持** |
| **4分** | PF <100 (有创通气) | PF ≤75 + 高级支持 **或 ECMO** |

**高级呼吸支持**: HFNC, CPAP, BiPAP, NIV, IMV（有创）

**实现关键点**:
- 使用 `mimiciv_derived.ventilation` 表
- 识别 ECMO (`chartevents` itemid: 228001, 229270, 229272)
- 区分有/无高级支持的 PF 比值

---

### 3. Cardiovascular（心血管）⭐⭐ **最大变化**

| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| **0分** | MAP ≥70，无升压药 | MAP ≥70，无升压药 |
| **1分** | MAP <70，无升压药 | MAP <70，无升压药 |
| **2分** | 任何 Dop 或 Dob | **NE+Epi ≤0.2** 或其他升压药 |
| **3分** | Dop >5 或 Epi/NE ≤0.1 | **NE+Epi 0.2-0.4** 或低剂量+其他 |
| **4分** | Dop >15 或 Epi/NE >0.1 | **NE+Epi >0.4** 或机械循环支持 |

**机械循环支持**: ECMO, IABP, LVAD, Impella

**实现关键点**:
- **合并去甲肾上腺素和肾上腺素剂量**: `NE_dose + Epi_dose`
- 需要患者体重转换为 μg/kg/min
- 识别机械循环支持设备

**关键验证指标**:
心血管系统 2 分患者比例应约为 **8.9%**（vs SOFA-1 的 0.9%）

---

### 4. Liver（肝脏）
**变化**: 阈值微调（< 改为 ≤）

| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| **0分** | Bilirubin **<** 1.2 | Bilirubin **≤** 1.2 |
| **1-4分** | 其他阈值相同 | 其他阈值相同 |

---

### 5. Kidney（肾脏）⭐ 重要更新

| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| **0分** | Cr <1.2 | Cr ≤1.2 |
| **1分** | Cr 1.2-2.0 | Cr ≤2.0 或 UO <0.5 ml/kg/h (6-12h) |
| **2分** | Cr 2.0-3.5 | Cr ≤3.5 或 UO <0.5 ml/kg/h (≥12h) |
| **3分** | Cr 3.5-5.0 或 UO <500ml/24h | Cr >3.5 或 UO <0.3 ml/kg/h (≥24h) |
| **4分** | Cr ≥5.0 或 UO <200ml/24h | **RRT 或符合 RRT 标准** |

**RRT 启动标准** (用于未接受 RRT 患者):
- Cr >1.2 mg/dL **且** 以下至少一项:
  - K ≥6.0 mmol/L
  - pH ≤7.2 **且** HCO3 ≤12 mmol/L

**实现关键点**:
- 尿量改为**体重基础** (ml/kg/h) 而非总量
- 需要患者体重数据
- 需要血钾、pH、碳酸氢盐数据
- 使用 `mimiciv_derived.rrt` 表检测透析

---

### 6. Hemostasis（凝血）
**变化**: 新增 3 分阈值（≤80）

| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| **0分** | PLT >150 | PLT >150 |
| **1分** | PLT <150 | PLT ≤150 |
| **2分** | PLT <100 | PLT ≤100 |
| **3分** | PLT <50 | PLT **≤80** |
| **4分** | PLT <20 | PLT **≤50** |

---

## 📊 SQL 实现架构

### 文件结构
```
sofa2_sql/
├── README.md                          # 使用文档
├── 00_helper_views.sql               # 辅助 CTE 模板
├── sofa2.sql                         # 每小时 SOFA-2（主文件）
├── first_day_sofa2.sql               # 首日 SOFA-2
├── sepsis3_sofa2.sql                 # Sepsis-3 识别
└── validation/
    └── compare_sofa1_sofa2.sql       # SOFA-1 vs SOFA-2 对比
```

### 核心技术实现

#### 1. 患者体重获取
```sql
WITH patient_weight AS (
    SELECT stay_id, weight
    FROM mimiciv_derived.first_day_weight
    WHERE weight IS NOT NULL AND weight > 0
)
```

#### 2. 谵妄药物检测
```sql
WITH delirium_meds AS (
    SELECT DISTINCT ie.stay_id, 1 AS on_delirium_med
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr
        ON ie.hadm_id = pr.hadm_id
    WHERE LOWER(pr.drug) LIKE '%haloperidol%'
       OR LOWER(pr.drug) LIKE '%quetiapine%'
       OR LOWER(pr.drug) LIKE '%olanzapine%'
       OR LOWER(pr.drug) LIKE '%risperidone%'
)
```

#### 3. 高级呼吸支持
```sql
WITH advanced_resp_support AS (
    SELECT stay_id, starttime, endtime, has_advanced_support
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'Tracheostomy',
                                  'NonInvasiveVent', 'HFNC')
)
```

#### 4. 机械循环支持
```sql
WITH mechanical_support AS (
    SELECT DISTINCT stay_id, has_mechanical_support
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (
        228001, 229270, 229272,  -- ECMO
        228000, 224797, 224798   -- IABP
    )
)
```

#### 5. RRT 与代谢标准
```sql
-- RRT 标准: Cr >1.2 AND (K ≥6.0 OR 酸中毒)
CASE
    WHEN on_rrt = 1 THEN 4
    WHEN creatinine_max > 1.2
         AND (potassium_max >= 6.0
              OR (ph_min <= 7.2 AND bicarbonate_min <= 12))
        THEN 4
    ...
END AS kidney
```

#### 6. 心血管评分（最复杂）
```sql
-- 合并 NE + Epi 剂量
CASE
    WHEN has_mechanical_support = 1 THEN 4
    WHEN (COALESCE(rate_norepinephrine, 0) +
          COALESCE(rate_epinephrine, 0)) > 0.4 THEN 4
    WHEN (NE + Epi) > 0.2 AND (NE + Epi) <= 0.4
         AND (dopamine > 0 OR dobutamine > 0) THEN 4
    WHEN (NE + Epi) > 0.2 AND (NE + Epi) <= 0.4 THEN 3
    ...
END AS cardiovascular
```

---

## ⚙️ 执行步骤

### 1. 数据库准备
```bash
# 确认连接
psql -h 172.19.160.1 -U postgres -d mimiciv

# 或使用 Python
conda activate rna-seq
python -c "from utils.db_helper import test_connection; test_connection('mimic')"
```

### 2. 执行 SQL 脚本
```sql
-- 方法 1: 直接在 PostgreSQL 中执行
\i /mnt/f/SaAki_Sofa_benchmark/sofa2_sql/sofa2.sql

-- 方法 2: 使用 Python
from utils.db_helper import execute_sql_file
execute_sql_file('sofa2_sql/sofa2.sql', db='mimic')
```

### 3. 创建派生表
```sql
-- 创建 SOFA-2 派生表 (类似 mimiciv_derived.sofa)
CREATE TABLE mimiciv_derived.sofa2 AS
    SELECT * FROM (
        -- sofa2.sql 的内容
        ...
    );

-- 创建首日 SOFA-2 表
CREATE TABLE mimiciv_derived.first_day_sofa2 AS
    SELECT * FROM (
        -- first_day_sofa2.sql 的内容
        ...
    );

-- 创建 Sepsis-3 (SOFA-2) 表
CREATE TABLE mimiciv_derived.sepsis3_sofa2 AS
    SELECT * FROM (
        -- sepsis3_sofa2.sql 的内容
        ...
    );
```

### 4. 验证结果
```sql
-- 运行验证脚本
\i /mnt/f/SaAki_Sofa_benchmark/sofa2_sql/validation/compare_sofa1_sofa2.sql
```

---

## ✅ 关键验证指标

### 1. 心血管系统 2 分比例
**预期**: ~8.9% (vs SOFA-1 的 ~0.9%)

```sql
SELECT
    ROUND(100.0 * COUNT(*) FILTER (WHERE cardiovascular_24hours = 2) /
          NULLIF(COUNT(*), 0), 2) AS cv_2point_pct
FROM mimiciv_derived.first_day_sofa2;
```

**如果不符合预期**, 检查:
- 去甲肾上腺素和肾上腺素剂量是否正确合并
- 剂量是否转换为 μg/kg/min
- 其他升压药（多巴胺、多巴酚丁胺）是否正确识别

### 2. 总分分布
**预期**: 中位数 ~3 (IQR 1-5)

```sql
SELECT
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sofa2_total) AS median,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sofa2_total) AS q1,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sofa2_total) AS q3
FROM mimiciv_derived.first_day_sofa2;
```

### 3. 与 SOFA-1 的相关性
**预期**: 高度相关但不完全相同

```sql
SELECT
    CORR(s1.sofa, s2.sofa2_total) AS correlation
FROM mimiciv_derived.first_day_sofa s1
INNER JOIN mimiciv_derived.first_day_sofa2 s2
    ON s1.stay_id = s2.stay_id;
```

### 4. Sepsis-3 识别差异
```sql
SELECT
    'SOFA-1 Sepsis-3' AS method,
    COUNT(*) AS n_sepsis
FROM mimiciv_derived.sepsis3
WHERE sepsis3 = TRUE

UNION ALL

SELECT
    'SOFA-2 Sepsis-3' AS method,
    COUNT(*) AS n_sepsis
FROM mimiciv_derived.sepsis3_sofa2
WHERE sepsis3 = TRUE;
```

---

## ⚠️ 常见问题和解决方案

### 问题 1: 患者体重缺失
**症状**: `uo_ml_kg_h` 或升压药剂量为 NULL

**解决**:
```sql
-- 使用默认体重 80kg 作为后备
COALESCE(weight, 80) AS weight
```

### 问题 2: 谵妄药物检测不到
**症状**: 所有患者的 `on_delirium_med` 都是 NULL

**检查**:
```sql
-- 检查 prescriptions 表中药物名称格式
SELECT DISTINCT drug
FROM mimiciv_hosp.prescriptions
WHERE LOWER(drug) LIKE '%haldol%'
   OR LOWER(drug) LIKE '%haloperidol%'
LIMIT 10;
```

### 问题 3: 机械支持设备识别不完整
**症状**: `has_mechanical_support` 总是 0

**检查**:
```sql
-- 验证 itemid
SELECT itemid, label, COUNT(*) AS n_events
FROM mimiciv_icu.chartevents ce
INNER JOIN mimiciv_icu.d_items di ON ce.itemid = di.itemid
WHERE LOWER(label) LIKE '%ecmo%'
   OR LOWER(label) LIKE '%iabp%'
GROUP BY itemid, label;
```

### 问题 4: RRT 代谢标准未触发
**症状**: 应该为 4 分的肾脏评分只有 3 分

**检查**:
```sql
-- 验证血气和化学数据
SELECT
    stay_id,
    creatinine_max,
    potassium_max,
    ph_min,
    bicarbonate_min
FROM mimiciv_derived.first_day_sofa2
WHERE kidney_24hours = 3
  AND (potassium_max >= 6.0 OR (ph_min <= 7.2 AND bicarbonate_min <= 12))
LIMIT 10;
```

---

## 📈 后续步骤（用于 SA-AKI Letter）

### 1. 构建 SA-AKI 队列
```sql
-- 结合 SOFA-2 和 AKI 识别
CREATE TABLE sa_aki_cohort AS
SELECT
    ie.stay_id,
    ie.subject_id,
    ie.hadm_id,
    -- SOFA-2
    s2.sofa2_total,
    s2.cardiovascular_24hours,
    s2.kidney_24hours,
    ...
    -- Sepsis-3 (SOFA-2)
    sep.sepsis3,
    -- AKI
    aki.aki_stage,
    -- 结局
    a.hospital_expire_flag AS mortality
FROM mimiciv_icu.icustays ie
INNER JOIN mimiciv_derived.first_day_sofa2 s2
    ON ie.stay_id = s2.stay_id
INNER JOIN mimiciv_derived.sepsis3_sofa2 sep
    ON ie.stay_id = sep.stay_id
INNER JOIN mimiciv_derived.kdigo_stages aki
    ON ie.stay_id = aki.stay_id
INNER JOIN mimiciv_hosp.admissions a
    ON ie.hadm_id = a.hadm_id
WHERE sep.sepsis3 = TRUE
  AND aki.aki_stage >= 1
  AND aki.charttime <= ie.intime + INTERVAL '48' HOUR;
```

### 2. 计算预测性能（Python）
```python
from sklearn.metrics import roc_auc_score, roc_curve
from scipy.stats import bootstrap

# 读取数据
from utils.db_helper import query_to_df

df = query_to_df("""
    SELECT sofa2_total, mortality
    FROM sa_aki_cohort
""", db='mimic')

# 计算 AUC
auc = roc_auc_score(df['mortality'], df['sofa2_total'])
print(f"SOFA-2 AUC: {auc:.3f}")

# Bootstrap 95% CI
def auc_func(y_true, y_score):
    return roc_auc_score(y_true, y_score)

res = bootstrap(
    (df['mortality'].values, df['sofa2_total'].values),
    auc_func,
    n_resamples=2000,
    method='percentile'
)

print(f"95% CI: ({res.confidence_interval.low:.3f}, {res.confidence_interval.high:.3f})")
```

### 3. DeLong 检验对比 SOFA-1 vs SOFA-2
```python
from scipy.stats import mannwhitneyu

# 需要使用专门的 DeLong 检验库
# pip install delong
from delong import delong_test

p_value = delong_test(
    df['mortality'],
    df['sofa1_total'],
    df['sofa2_total']
)

print(f"DeLong test p-value: {p_value:.4f}")
```

---

## 📚 参考资料

### 关键文献
1. **Ranzani OT, Singer M, Salluh JIF, et al.** Development and Validation of the Sequential Organ Failure Assessment (SOFA)-2 Score. *JAMA*. 2025. doi:10.1001/jama.2025.20516

2. **Singer M, Deutschman CS, Seymour CW, et al.** The Third International Consensus Definitions for Sepsis and Septic Shock (Sepsis-3). *JAMA*. 2016;315(8):801-810.

3. **Vincent JL, Moreno R, Takala J, et al.** The SOFA (Sepsis-related Organ Failure Assessment) score to describe organ dysfunction/failure. *Intensive Care Med*. 1996;22(7):707-710.

### 本地文档
- SOFA-2 标准详解: `/mnt/f/SaAki_Sofa_benchmark/SOFA2_评分标准详解.md`
- 研究方案: `/mnt/f/SaAki_Sofa_benchmark/研究方案_SOFA2_SA-AKI_Letter.md`
- 快速执行计划: `/mnt/f/SaAki_Sofa_benchmark/快速执行计划_Letter产出.md`
- MIMIC-IV 技能: `/.claude/skills/mimiciv-data-extraction/SKILL.md`

---

## 🎯 成功标准

### SQL 实现成功标准
- ✅ 所有 SQL 脚本无错误执行
- ✅ 心血管系统 2 分比例 ~8-9%
- ✅ 总分中位数在合理范围 (2-4)
- ✅ 与 SOFA-1 高度相关 (r >0.85)

### 研究成功标准（后续）
- ✅ SA-AKI 队列构建成功 (>3000 例)
- ✅ SOFA-2 AUC 在 0.75-0.85 范围
- ✅ 与 SOFA-1 对比具有统计学意义
- ✅ Letter 投稿至 ICM 或 Critical Care

---

## 📧 维护和更新

**创建者**: Claude AI
**创建日期**: 2025-11-14
**版本**: 1.0

**后续更新计划**:
1. 执行验证并根据结果调整
2. 优化性能（如果查询速度慢）
3. 添加更多验证指标
4. 创建 Python 包装函数

**问题反馈**:
- 检查 `validation/compare_sofa1_sofa2.sql` 输出
- 参考 SOFA-2 标准详解文档
- 使用 MIMIC-IV 技能获取表结构信息

---

**状态**: ✅ SQL 实现完成，准备执行和验证！
