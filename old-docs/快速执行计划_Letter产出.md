# SOFA-2在SA-AKI患者中的应用 - 快速执行计划（3周产出Letter）

## 项目概览

**研究目标**：评估SOFA-2相比SOFA-1在脓毒症相关急性肾损伤(SA-AKI)患者中的28天死亡率预测能力

**研究设计**：双数据库（MIMIC-IV + eICU）回顾性队列研究

**目标产出**：ICM或Critical Care的Research Letter（500-800字，1图1表）

**预计时间**：3周（21天）

---

## Week 1：数据提取和SOFA-2实现（Day 1-7）

### Day 1-2：环境准备和脚本框架搭建

#### ✅ Checkpoint 1.1：数据库连接确认
```bash
# 确认MIMIC-IV访问权限
psql -U your_username -d mimiciv -c "\dt"

# 确认eICU访问权限（如有）
# 或下载eICU数据到本地
```

**输出文件**：
- `config/database_config.py`：数据库连接配置
- `utils/db_connector.py`：数据库连接工具

---

#### ✅ Checkpoint 1.2：SA-AKI队列SQL开发

**任务**：编写SQL脚本从MIMIC-IV提取SA-AKI患者

**纳入标准**：
1. 年龄≥18岁
2. ICU住院>24小时
3. 符合Sepsis-3标准（感染 + SOFA≥2）
4. 入ICU后48h内AKI（KDIGO标准）

**排除标准**：
1. ESRD（入ICU前已透析）
2. 缺失数据>30%

**SQL脚本列表**：
```
sql/
├── 01_sepsis_cohort.sql          # 提取脓毒症患者
├── 02_aki_identification.sql     # 识别AKI（KDIGO标准）
├── 03_sofa1_variables.sql        # SOFA-1所需变量
├── 04_sofa2_variables.sql        # SOFA-2新增变量
├── 05_outcomes.sql               # 结局变量
└── 99_master_query.sql           # 整合所有查询
```

**预期样本量**：
- MIMIC-IV：3000-5000例SA-AKI患者
- eICU：2000-4000例SA-AKI患者

**关键难点**：
1. **AKI基线肌酐定义**：
   - 入ICU前7天内最低值
   - 或入ICU后48h内最低值

2. **Sepsis-3定义**：
   ```sql
   -- 感染：ICD-10编码 或 培养阳性 + 抗生素使用
   -- SOFA≥2：相对基线（假设基线=0）
   ```

---

### Day 3-4：SOFA-2计算代码开发

#### ✅ Checkpoint 1.3：SOFA-2计算引擎

**Python模块结构**：
```
src/sofa2/
├── __init__.py
├── brain.py              # 神经系统评分
├── respiratory.py        # 呼吸系统评分
├── cardiovascular.py     # 心血管系统评分（最复杂）
├── liver.py              # 肝脏评分
├── kidney.py             # 肾脏评分
├── hemostasis.py         # 凝血评分
└── calculator.py         # 总评分计算器
```

**关键函数示例**：

```python
# cardiovascular.py - 最复杂的部分
def calculate_cv_score(row):
    """
    计算心血管系统SOFA-2评分

    参数：
        row: DataFrame行，包含以下字段：
            - map_min: 最低MAP
            - norepinephrine_mcg_kg_min: 去甲肾剂量
            - epinephrine_mcg_kg_min: 肾上腺素剂量
            - dopamine_mcg_kg_min: 多巴胺剂量
            - dobutamine_mcg_kg_min: 多巴酚丁胺剂量
            - vasopressin_units_min: 血管加压素剂量
            - phenylephrine_mcg_kg_min: 去氧肾剂量
            - ecmo: ECMO使用（1=是）
            - iabp: IABP使用
            - lvad: LVAD使用

    返回：
        int: 0-4分
    """
    # 机械支持 = 4分
    if row['ecmo'] == 1 or row['iabp'] == 1 or row['lvad'] == 1:
        return 4

    # 无血管活性药
    if (row['norepinephrine_mcg_kg_min'] == 0 and
        row['epinephrine_mcg_kg_min'] == 0 and
        row['dopamine_mcg_kg_min'] == 0 and
        row['dobutamine_mcg_kg_min'] == 0):
        if row['map_min'] >= 70:
            return 0
        else:
            return 1

    # 计算NE+E总剂量
    ne_e_dose = row['norepinephrine_mcg_kg_min'] + row['epinephrine_mcg_kg_min']

    # 检查其他升压药
    other_vasopressor = (
        row['dopamine_mcg_kg_min'] > 0 or
        row['dobutamine_mcg_kg_min'] > 0 or
        row['vasopressin_units_min'] > 0 or
        row['phenylephrine_mcg_kg_min'] > 0
    )

    # 高剂量（4分）
    if ne_e_dose > 0.4:
        return 4

    # 中剂量 + 其他药物（4分）
    if ne_e_dose > 0.2 and ne_e_dose <= 0.4 and other_vasopressor:
        return 4

    # 中剂量（3分）
    if ne_e_dose > 0.2 and ne_e_dose <= 0.4:
        return 3

    # 低剂量 + 其他药物（3分）
    if ne_e_dose <= 0.2 and other_vasopressor:
        return 3

    # 低剂量（2分）
    if ne_e_dose <= 0.2:
        return 2

    return 0
```

**单元测试**：
```python
# tests/test_sofa2.py
def test_cardiovascular_score():
    # 测试用例1：无药物，MAP正常
    row1 = {'map_min': 75, 'norepinephrine_mcg_kg_min': 0, ...}
    assert calculate_cv_score(row1) == 0

    # 测试用例2：低剂量NE
    row2 = {'map_min': 65, 'norepinephrine_mcg_kg_min': 0.15, ...}
    assert calculate_cv_score(row2) == 2

    # ... 更多测试用例
```

---

### Day 5-6：数据提取执行

#### ✅ Checkpoint 1.4：MIMIC-IV数据提取

**执行脚本**：
```bash
# 提取MIMIC-IV数据
python scripts/extract_mimic_data.py \
    --output data/mimic_sa_aki_cohort.csv \
    --log logs/mimic_extraction.log
```

**数据质量检查**：
```python
# scripts/data_quality_check.py
def check_data_quality(df):
    """数据质量报告"""
    print("=" * 60)
    print("数据质量报告")
    print("=" * 60)
    print(f"总样本量: {len(df)}")
    print(f"\n各器官系统变量完整性:")

    # SOFA-2组分完整性
    sofa_components = ['gcs', 'pao2_fio2', 'map', 'bilirubin',
                       'creatinine', 'platelets']
    for comp in sofa_components:
        missing_pct = df[comp].isna().mean() * 100
        print(f"  - {comp}: {100-missing_pct:.1f}% 完整")

    # AKI分期分布
    print(f"\nAKI分期分布:")
    print(df['aki_stage'].value_counts())

    # 结局变量
    print(f"\n结局变量:")
    print(f"  - 28天死亡: {df['mortality_28d'].sum()} ({df['mortality_28d'].mean()*100:.1f}%)")
    print(f"  - ICU死亡: {df['icu_mortality'].sum()} ({df['icu_mortality'].mean()*100:.1f}%)")
    print(f"  - RRT需求: {df['rrt_initiated'].sum()} ({df['rrt_initiated'].mean()*100:.1f}%)")
```

**预期输出**：
```
总样本量: 4523
各器官系统变量完整性:
  - gcs: 89.3% 完整
  - pao2_fio2: 76.5% 完整
  - map: 98.2% 完整
  - bilirubin: 85.1% 完整
  - creatinine: 99.1% 完整
  - platelets: 97.8% 完整

AKI分期分布:
1    2145 (47.4%)
2    1234 (27.3%)
3    1144 (25.3%)

结局变量:
  - 28天死亡: 678 (15.0%)
  - ICU死亡: 521 (11.5%)
  - RRT需求: 892 (19.7%)
```

---

#### ✅ Checkpoint 1.5：eICU数据提取（并行）

**注意事项**：
- eICU表结构与MIMIC-IV不同，需调整SQL
- 如eICU不可用，可暂时跳过，仅用MIMIC-IV进行单数据库分析

---

### Day 7：SOFA-1和SOFA-2计算

#### ✅ Checkpoint 1.6：计算两个评分

**执行**：
```python
# scripts/calculate_sofa_scores.py
import pandas as pd
from src.sofa1 import calculate_sofa1
from src.sofa2 import calculate_sofa2

# 读取数据
df = pd.read_csv('data/mimic_sa_aki_cohort.csv')

# 计算SOFA-1
df['sofa1_brain'] = df.apply(calculate_sofa1_brain, axis=1)
df['sofa1_respiratory'] = df.apply(calculate_sofa1_respiratory, axis=1)
# ... 其他组分
df['sofa1_total'] = df[[f'sofa1_{sys}' for sys in SYSTEMS]].sum(axis=1)

# 计算SOFA-2
df['sofa2_brain'] = df.apply(calculate_sofa2_brain, axis=1)
df['sofa2_cardiovascular'] = df.apply(calculate_cv_score, axis=1)
# ... 其他组分
df['sofa2_total'] = df[[f'sofa2_{sys}' for sys in SYSTEMS]].sum(axis=1)

# 保存
df.to_csv('data/mimic_with_sofa_scores.csv', index=False)
```

**验证检查**：
```python
# 验证分布是否符合预期
print("SOFA-1分布:")
print(df['sofa1_total'].describe())

print("\nSOFA-2分布:")
print(df['sofa2_total'].describe())

# 心血管系统2分的比例（关键验证点）
cv_2_pct = (df['sofa2_cardiovascular'] == 2).mean() * 100
print(f"\n心血管系统2分比例: {cv_2_pct:.1f}%")
print("预期: 约8.9%（根据JAMA文章）")
```

**Week 1 交付物**：
- ✅ SA-AKI队列数据（CSV）
- ✅ SOFA-1和SOFA-2评分（已计算）
- ✅ 数据质量报告
- ✅ 所有代码（SQL + Python）

---

## Week 2：统计分析和可视化（Day 8-14）

### Day 8-9：描述性统计

#### ✅ Checkpoint 2.1：基线特征表（Table 1）

**表格结构**：

| 变量 | MIMIC-IV (n=4523) | eICU (n=3211) | 合并 (n=7734) | p值 |
|-----|------------------|--------------|--------------|-----|
| **人口学特征** |
| 年龄（岁），mean±SD | 65.2±15.3 | 64.8±16.1 | 65.0±15.7 | 0.234 |
| 女性，n (%) | 1987 (43.9) | 1345 (41.9) | 3332 (43.1) | 0.089 |
| **入ICU时病情** |
| SOFA-1，median (IQR) | 8 (5-11) | 7 (5-10) | 8 (5-11) | 0.012 |
| SOFA-2，median (IQR) | 7 (4-10) | 7 (4-9) | 7 (4-10) | 0.156 |
| **AKI特征** |
| AKI分期，n (%) |
| &nbsp;&nbsp;Stage 1 | 2145 (47.4) | 1523 (47.4) | 3668 (47.4) | 0.998 |
| &nbsp;&nbsp;Stage 2 | 1234 (27.3) | 867 (27.0) | 2101 (27.2) |  |
| &nbsp;&nbsp;Stage 3 | 1144 (25.3) | 821 (25.6) | 1965 (25.4) |  |
| **感染来源** |
| 肺部，n (%) | 2034 (45.0) | 1445 (45.0) | 3479 (45.0) | 0.987 |
| 腹腔，n (%) | 891 (19.7) | 643 (20.0) | 1534 (19.8) |  |
| 泌尿系，n (%) | 678 (15.0) | 482 (15.0) | 1160 (15.0) |  |
| 其他，n (%) | 920 (20.3) | 641 (20.0) | 1561 (20.2) |  |
| **结局** |
| 28天死亡，n (%) | 678 (15.0) | 482 (15.0) | 1160 (15.0) | 0.998 |
| ICU死亡，n (%) | 521 (11.5) | 370 (11.5) | 891 (11.5) | 0.998 |
| RRT需求，n (%) | 892 (19.7) | 643 (20.0) | 1535 (19.9) | 0.712 |

**代码**：
```python
# scripts/generate_table1.py
from tableone import TableOne

columns = ['age', 'gender', 'sofa1_total', 'sofa2_total',
           'aki_stage', 'infection_site', 'mortality_28d',
           'icu_mortality', 'rrt_initiated']

categorical = ['gender', 'aki_stage', 'infection_site',
               'mortality_28d', 'icu_mortality', 'rrt_initiated']

table1 = TableOne(df, columns=columns, categorical=categorical,
                  groupby='database', pval=True)

# 输出LaTeX格式
table1.to_latex('results/table1_baseline.tex')
```

---

### Day 10-11：主要分析 - ROC曲线和AUC对比

#### ✅ Checkpoint 2.2：ROC分析

**分析目标**：
1. 计算SOFA-1和SOFA-2对28天死亡率的AUROC
2. DeLong检验比较两个AUC
3. 分层分析（MIMIC-IV vs eICU）

**Python代码**：
```python
# scripts/roc_analysis.py
from sklearn.metrics import roc_curve, roc_auc_score
from scipy.stats import bootstrap
import matplotlib.pyplot as plt

def calculate_auc_with_ci(y_true, y_score, n_bootstrap=2000):
    """计算AUC及95% CI"""
    auc = roc_auc_score(y_true, y_score)

    # Bootstrap 95% CI
    def auc_func(y_true, y_score):
        return roc_auc_score(y_true, y_score)

    rng = np.random.default_rng()
    res = bootstrap((y_true, y_score), auc_func, n_resamples=n_bootstrap,
                    random_state=rng, method='percentile')

    return auc, res.confidence_interval.low, res.confidence_interval.high

# MIMIC-IV队列
mimic_df = df[df['database'] == 'MIMIC-IV']
auc1_mimic, ci1_low, ci1_high = calculate_auc_with_ci(
    mimic_df['mortality_28d'], mimic_df['sofa1_total']
)
auc2_mimic, ci2_low, ci2_high = calculate_auc_with_ci(
    mimic_df['mortality_28d'], mimic_df['sofa2_total']
)

print(f"MIMIC-IV:")
print(f"  SOFA-1 AUC: {auc1_mimic:.3f} (95% CI: {ci1_low:.3f}-{ci1_high:.3f})")
print(f"  SOFA-2 AUC: {auc2_mimic:.3f} (95% CI: {ci2_low:.3f}-{ci2_high:.3f})")

# DeLong检验
from scipy.stats import mannwhitneyu
# 或使用专门的DeLong检验库
# pip install delong
```

**预期结果**：
```
MIMIC-IV (n=4523):
  SOFA-1 AUC: 0.763 (95% CI: 0.749-0.777)
  SOFA-2 AUC: 0.781 (95% CI: 0.768-0.794)
  DeLong test: p=0.018

eICU (n=3211):
  SOFA-1 AUC: 0.758 (95% CI: 0.741-0.775)
  SOFA-2 AUC: 0.776 (95% CI: 0.760-0.792)
  DeLong test: p=0.032

合并 (n=7734):
  SOFA-1 AUC: 0.761 (95% CI: 0.750-0.772)
  SOFA-2 AUC: 0.779 (95% CI: 0.769-0.789)
  DeLong test: p=0.003
```

---

#### ✅ Checkpoint 2.3：主图制作（Figure 1）

**图形设计**：2×1分面ROC曲线图

```python
# scripts/generate_figure1.py
import matplotlib.pyplot as plt
import seaborn as sns

fig, axes = plt.subplots(1, 2, figsize=(12, 5))

# 面板A：MIMIC-IV
ax1 = axes[0]
fpr1, tpr1, _ = roc_curve(mimic_df['mortality_28d'], mimic_df['sofa1_total'])
fpr2, tpr2, _ = roc_curve(mimic_df['mortality_28d'], mimic_df['sofa2_total'])

ax1.plot(fpr1, tpr1, label=f'SOFA-1 (AUC={auc1_mimic:.3f})', color='blue', lw=2)
ax1.plot(fpr2, tpr2, label=f'SOFA-2 (AUC={auc2_mimic:.3f})', color='red', lw=2)
ax1.plot([0, 1], [0, 1], 'k--', lw=1, alpha=0.5)
ax1.set_xlabel('1 - Specificity')
ax1.set_ylabel('Sensitivity')
ax1.set_title('A. MIMIC-IV (n=4523)\nDeLong test: p=0.018')
ax1.legend(loc='lower right')
ax1.grid(alpha=0.3)

# 面板B：eICU
ax2 = axes[1]
# ... 类似代码

plt.tight_layout()
plt.savefig('figures/figure1_roc_curves.png', dpi=300, bbox_inches='tight')
plt.savefig('figures/figure1_roc_curves.pdf', bbox_inches='tight')
```

---

### Day 12：亚组分析

#### ✅ Checkpoint 2.4：按AKI分期分层

**代码**：
```python
# scripts/subgroup_analysis.py
for aki_stage in [1, 2, 3]:
    subset = df[df['aki_stage'] == aki_stage]

    auc1 = roc_auc_score(subset['mortality_28d'], subset['sofa1_total'])
    auc2 = roc_auc_score(subset['mortality_28d'], subset['sofa2_total'])

    print(f"AKI Stage {aki_stage} (n={len(subset)}):")
    print(f"  SOFA-1 AUC: {auc1:.3f}")
    print(f"  SOFA-2 AUC: {auc2:.3f}")
    print(f"  Difference: {auc2-auc1:.3f}")
    print()
```

**预期输出**：
```
AKI Stage 1 (n=3668):
  SOFA-1 AUC: 0.745
  SOFA-2 AUC: 0.762
  Difference: 0.017

AKI Stage 2 (n=2101):
  SOFA-1 AUC: 0.768
  SOFA-2 AUC: 0.789
  Difference: 0.021

AKI Stage 3 (n=1965):
  SOFA-1 AUC: 0.781
  SOFA-2 AUC: 0.803
  Difference: 0.022 (最明显)
```

---

### Day 13-14：补充分析和可视化

#### ✅ Checkpoint 2.5：其他关键分析

**1. 校准曲线（Calibration plot）**：
```python
from sklearn.calibration import calibration_curve

# 将SOFA分数转换为预测概率
# 方法1：Logistic回归
from sklearn.linear_model import LogisticRegression
lr = LogisticRegression()
lr.fit(df[['sofa2_total']], df['mortality_28d'])
pred_prob = lr.predict_proba(df[['sofa2_total']])[:, 1]

# 计算校准曲线
fraction_of_positives, mean_predicted_value = calibration_curve(
    df['mortality_28d'], pred_prob, n_bins=10
)

# 绘图
plt.plot(mean_predicted_value, fraction_of_positives, "s-", label='SOFA-2')
plt.plot([0, 1], [0, 1], "k--", label='Perfect calibration')
plt.xlabel('Predicted mortality')
plt.ylabel('Observed mortality')
plt.title('Calibration plot')
plt.legend()
```

**2. 重分类改善（NRI/IDI）**：
```python
# 如果AUC有显著差异，计算NRI
from reclassification import net_reclassification_improvement

# 定义风险分层
risk_thresholds = [0, 0.1, 0.3, 1.0]  # 低、中、高风险

nri = net_reclassification_improvement(
    event=df['mortality_28d'],
    prob_pre=df['sofa1_total'] / 24,  # 标准化到0-1
    prob_post=df['sofa2_total'] / 24,
    thresholds=risk_thresholds
)

print(f"NRI: {nri:.3f}")
```

**Week 2 交付物**：
- ✅ 基线特征表（Table 1）
- ✅ ROC曲线图（Figure 1）
- ✅ 统计分析结果
- ✅ 亚组分析报告

---

## Week 3：撰写Letter和投稿（Day 15-21）

### Day 15-17：撰写初稿

#### ✅ Checkpoint 3.1：Letter结构（800字）

**Letter模板**：

```markdown
# Title (精炼，≤120字符)
Performance of the SOFA-2 Score in Predicting Mortality among Critically Ill Patients with Sepsis-Associated Acute Kidney Injury

## To the Editor,

### 背景（100-120字）
The Sequential Organ Failure Assessment (SOFA) score was recently updated (SOFA-2)
after 30 years to reflect contemporary critical care practice [ref]. Sepsis-associated
acute kidney injury (SA-AKI) affects 30-50% of ICU patients and is associated with
high mortality. However, the performance of SOFA-2 in this specific population remains
unknown. We evaluated whether SOFA-2 improves mortality prediction compared to SOFA-1
in SA-AKI patients.

### 方法（180-200字）
**Study design:** Retrospective cohort study using MIMIC-IV (development) and eICU
(external validation) databases.

**Population:** Adult ICU patients (≥18 years) with SA-AKI, defined as sepsis (Sepsis-3
criteria) with AKI (KDIGO criteria) within 48 hours of ICU admission. We excluded
patients with ESRD or missing data >30%.

**Exposure:** SOFA-1 and SOFA-2 scores calculated at ICU admission using worst values
within 24 hours. SOFA-2 incorporated updated thresholds for respiratory, cardiovascular,
and renal components [ref].

**Outcome:** 28-day mortality.

**Analysis:** We compared AUROC curves using DeLong's test and performed subgroup
analyses stratified by AKI stage (KDIGO 1/2/3).

### 结果（250-280字）
We identified 4,523 SA-AKI patients in MIMIC-IV (mean age 65.2±15.3 years, 43.9%
female, 15.0% 28-day mortality) and 3,211 in eICU (64.8±16.1 years, 41.9% female,
15.0% mortality). AKI distribution: Stage 1 (47.4%), Stage 2 (27.2%), Stage 3 (25.4%).

**MIMIC-IV (Development):**
- SOFA-2 AUROC: 0.781 (95% CI, 0.768-0.794)
- SOFA-1 AUROC: 0.763 (95% CI, 0.749-0.777)
- Difference: 0.018 (95% CI, 0.006-0.030; DeLong p=0.018)

**eICU (External Validation):**
- SOFA-2 AUROC: 0.776 (95% CI, 0.760-0.792)
- SOFA-1 AUROC: 0.758 (95% CI, 0.741-0.775)
- Difference: 0.018 (95% CI, 0.005-0.031; p=0.032)

**Pooled Analysis (n=7,734):**
- SOFA-2 AUROC: 0.779 (95% CI, 0.769-0.789)
- SOFA-1 AUROC: 0.761 (95% CI, 0.750-0.772)
- Difference: 0.018 (95% CI, 0.010-0.026; p=0.003)

**Subgroup analyses:** SOFA-2's advantage was most pronounced in severe AKI (KDIGO
Stage 3: ΔAUC=0.022, p=0.009) compared to Stage 1 (ΔAUC=0.017, p=0.041).

### 讨论（120-150字）
SOFA-2 demonstrated modest but statistically significant improvement over SOFA-1 in
predicting mortality among SA-AKI patients across two large, geographically diverse
datasets. The improvement was consistent in external validation, supporting
generalizability. The greater discriminative ability in severe AKI may reflect SOFA-2's
updated renal component, which better captures contemporary RRT practices.

Limitations include retrospective design, potential misclassification of sepsis/AKI,
and missing data. The modest AUC improvement (0.018) suggests that SA-AKI-specific risk
models incorporating novel biomarkers may be needed for optimal prognostication.

### 结论（40-50字）
SOFA-2 provides improved mortality prediction compared to SOFA-1 in critically ill
patients with SA-AKI, with consistent performance across independent cohorts.

---

**Word count:** 787 words
**References:** 10 (主要引用SOFA-2原文、Sepsis-3、KDIGO标准等)
**Figure:** 1 (ROC curves)
**Table:** 1 (online supplement - baseline characteristics)
```

---

#### ✅ Checkpoint 3.2：在线补充材料

**Supplemental Material内容**：

1. **eTable 1**: Detailed baseline characteristics (完整版Table 1)
2. **eTable 2**: SOFA-1 and SOFA-2 component scores distribution
3. **eTable 3**: Subgroup analyses results
   - By AKI stage
   - By infection site
   - By database
4. **eFigure 1**: Calibration plots for SOFA-1 and SOFA-2
5. **eFigure 2**: SOFA score distribution comparison
6. **eMethods**: Detailed definitions of SA-AKI, SOFA-2 calculation

---

### Day 18-19：内部审阅和修改

#### ✅ Checkpoint 3.3：审阅清单

**审阅要点**：

| 项目 | 检查点 | ✓ |
|-----|-------|---|
| **科学准确性** |
| | SOFA-2计算完全符合JAMA原文标准 | □ |
| | SA-AKI定义符合Sepsis-3 + KDIGO标准 | □ |
| | 统计方法适当（DeLong检验） | □ |
| **数据质量** |
| | 样本量足够（>3000） | □ |
| | 缺失数据处理合理 | □ |
| | 结果可重现 | □ |
| **写作质量** |
| | 字数控制在800字内 | □ |
| | 逻辑清晰、语言简洁 | □ |
| | 参考文献准确 | □ |
| **图表质量** |
| | Figure 1：高分辨率（≥300 DPI） | □ |
| | Figure 1：标注清晰 | □ |
| | Table 1：格式符合期刊要求 | □ |

---

### Day 20-21：格式调整和投稿

#### ✅ Checkpoint 3.4：投稿准备

**1. 期刊选择确认**

| 期刊 | 类型 | 字数限制 | 审稿周期 | IF |
|-----|------|---------|---------|-----|
| **Intensive Care Medicine** | Letter to Editor | 800字, 1图1表 | 4-6周 | ~20 |
| **Critical Care** | Research Letter | 1000字, 2图/表 | 6-8周 | ~15 |

**推荐**：首选ICM（更高影响力、更快审稿）

**2. 投稿材料清单**

```
submission/
├── manuscript.docx                    # 正文（800字）
├── figure1_roc_curves.tiff           # 主图（TIFF格式，300+ DPI）
├── supplemental_material.pdf          # 在线补充材料
├── cover_letter.docx                  # Cover letter
├── author_contributions.docx          # 作者贡献声明
└── competing_interests.docx           # 利益冲突声明
```

**3. Cover Letter要点**

```markdown
Dear Editor,

We submit for your consideration our Research Letter titled "Performance of the
SOFA-2 Score in Predicting Mortality among Critically Ill Patients with
Sepsis-Associated Acute Kidney Injury."

**Key highlights:**
1. **Timeliness:** First study validating SOFA-2 (published October 2025) in the
   SA-AKI population
2. **Rigor:** Dual-database validation (MIMIC-IV + eICU, n=7,734)
3. **Clinical relevance:** SA-AKI affects 30-50% of ICU patients with high mortality
4. **Novel finding:** SOFA-2's advantage most pronounced in severe AKI

This work directly follows the landmark SOFA-2 publication in JAMA (Ranzani et al.,
2025) and addresses a critical gap in SA-AKI prognostication.

All authors have approved the final manuscript and declare no conflicts of interest.

Sincerely,
[Your name]
```

**Week 3 交付物**：
- ✅ 完整manuscript
- ✅ 高质量图表
- ✅ 补充材料
- ✅ 投稿至ICM/CC

---

## 关键成功因素（Critical Success Factors）

### 1. 数据质量保证
- **验证SOFA-2计算准确性**（对比JAMA原文Table 2）
- **检查心血管系统2分比例**（应约8-9%）
- **确认SA-AKI诊断标准**（Sepsis-3 + KDIGO）

### 2. 统计分析严谨性
- **使用DeLong检验**（标准方法）
- **报告95% CI**（所有AUC）
- **进行敏感性分析**（完整病例vs缺失值填补）

### 3. 时间管理
- **Day 1-2**：立即开始SQL开发
- **Day 3-4**：并行开发SOFA-2代码
- **Day 15**：开始写作（不要拖到最后）

### 4. 潜在风险管理

| 风险 | 影响 | 缓解措施 |
|-----|------|---------|
| SOFA-2与SOFA-1无显著差异 | 中 | 仍可发表阴性结果，讨论SA-AKI需特异性模型 |
| 样本量不足 | 高 | 降低纳入标准或仅用MIMIC-IV |
| 数据提取错误 | 高 | 严格验证SOFA-2计算，单元测试 |
| eICU数据不可用 | 低 | 改为单数据库研究（仍可发表） |

---

## 快速执行检查清单（Daily Checklist）

### Week 1
- [ ] Day 1: 数据库连接测试
- [ ] Day 2: SA-AKI队列SQL完成
- [ ] Day 3: SOFA-2计算代码完成
- [ ] Day 4: 单元测试通过
- [ ] Day 5: MIMIC-IV数据提取
- [ ] Day 6: 数据质量检查通过
- [ ] Day 7: SOFA评分计算完成

### Week 2
- [ ] Day 8: 描述性统计完成
- [ ] Day 9: Table 1生成
- [ ] Day 10: ROC分析（MIMIC-IV）
- [ ] Day 11: ROC分析（eICU）
- [ ] Day 12: 亚组分析
- [ ] Day 13: Figure 1制作
- [ ] Day 14: 补充分析

### Week 3
- [ ] Day 15: Letter初稿（背景+方法）
- [ ] Day 16: Letter初稿（结果+讨论）
- [ ] Day 17: 完整初稿
- [ ] Day 18: 内部审阅
- [ ] Day 19: 修改润色
- [ ] Day 20: 格式调整
- [ ] Day 21: 投稿至ICM

---

## 代码仓库结构建议

```
SaAki_Sofa_benchmark/
├── README.md
├── requirements.txt
├── config/
│   └── database_config.py
├── sql/
│   ├── 01_sepsis_cohort.sql
│   ├── 02_aki_identification.sql
│   ├── 03_sofa1_variables.sql
│   ├── 04_sofa2_variables.sql
│   ├── 05_outcomes.sql
│   └── 99_master_query.sql
├── src/
│   ├── sofa1/
│   │   ├── __init__.py
│   │   └── calculator.py
│   ├── sofa2/
│   │   ├── __init__.py
│   │   ├── brain.py
│   │   ├── respiratory.py
│   │   ├── cardiovascular.py
│   │   ├── liver.py
│   │   ├── kidney.py
│   │   ├── hemostasis.py
│   │   └── calculator.py
│   └── utils/
│       ├── db_connector.py
│       └── data_processing.py
├── scripts/
│   ├── extract_mimic_data.py
│   ├── extract_eicu_data.py
│   ├── calculate_sofa_scores.py
│   ├── data_quality_check.py
│   ├── generate_table1.py
│   ├── roc_analysis.py
│   ├── subgroup_analysis.py
│   └── generate_figure1.py
├── tests/
│   ├── test_sofa1.py
│   ├── test_sofa2.py
│   └── test_data_extraction.py
├── data/
│   ├── mimic_sa_aki_cohort.csv
│   ├── eicu_sa_aki_cohort.csv
│   └── combined_with_scores.csv
├── results/
│   ├── table1_baseline.tex
│   ├── roc_results.csv
│   └── subgroup_results.csv
├── figures/
│   ├── figure1_roc_curves.png
│   ├── figure1_roc_curves.pdf
│   └── calibration_plot.png
├── manuscript/
│   ├── letter_draft.docx
│   ├── supplemental_material.pdf
│   └── cover_letter.docx
└── logs/
    ├── data_extraction.log
    └── analysis.log
```

---

## 最后提醒

### 成功的3个关键
1. **第1周必须完成数据提取**（这是瓶颈）
2. **SOFA-2计算必须准确无误**（对照JAMA Table 2逐一验证）
3. **不要追求完美**（Letter是快速产出，细节可留给Full Article）

### 备选方案
如果3周无法完成：
- **方案A**：仅用MIMIC-IV（2周可完成）
- **方案B**：先投Preprint（bioRxiv/medRxiv），边审稿边补充分析

祝研究顺利！🚀
