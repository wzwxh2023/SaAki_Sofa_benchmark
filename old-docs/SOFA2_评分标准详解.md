# SOFA-2 评分标准详解（基于JAMA 2025）

## 一、SOFA-2评分系统总览

- **总分范围**：0-24分
- **计算方法**：6个器官系统各自独立评分（0-4分），取24小时内最差值
- **关键原则**：缺失值默认为0分（视为正常）

---

## 二、6个器官系统详细评分标准

### 1. Brain（神经系统/脑）

| 分数 | 标准 |
|-----|------|
| **0分** | GCS = 15（或竖大拇指、握拳、比和平手势） |
| **1分** | GCS 13-14（或对疼痛定位反应）<br>**或** 需要谵妄治疗药物 |
| **2分** | GCS 9-12（或对疼痛退缩反应） |
| **3分** | GCS 6-8（或对疼痛屈曲反应） |
| **4分** | GCS 3-5（或对疼痛伸展反应、无反应、全身性肌阵挛） |

**重要注释**：
- 对于镇静患者：使用镇静前最后一次GCS
- 如无法评估3个GCS域：使用运动域最佳分数
- 如正在接受谵妄治疗药物（短期或长期）：即使GCS=15也评1分

---

### 2. Respiratory（呼吸系统）⭐重大更新

| 分数 | 标准 |
|-----|------|
| **0分** | PaO₂:FiO₂ >300 mmHg (>40 kPa) |
| **1分** | PaO₂:FiO₂ ≤300 mmHg (≤40 kPa) |
| **2分** | PaO₂:FiO₂ ≤225 mmHg (≤30 kPa) |
| **3分** | PaO₂:FiO₂ ≤150 mmHg (≤20 kPa) <br>**且** 接受高级呼吸支持 |
| **4分** | PaO₂:FiO₂ ≤75 mmHg (≤10 kPa) **且** 高级呼吸支持<br>**或** 接受ECMO（呼吸适应症） |

**高级呼吸支持定义**：
- 高流量鼻导管（HFNC）
- 持续气道正压（CPAP）
- 双水平气道正压（BiPAP）
- 无创通气（NIV）
- 有创机械通气（IMV）
- 长期家庭通气

**替代指标（当PaO₂:FiO₂不可用时）**：
使用 SpO₂:FiO₂ 比值（仅当SpO₂ <98%时）：
- 0分: >300
- 1分: ≤300
- 2分: ≤250
- 3分: ≤200（需呼吸支持）
- 4分: ≤120（需呼吸支持或ECMO）

**特殊情况**：
- 如不具备呼吸支持条件或治疗上限：仅用PaO₂:FiO₂比值评分
- ECMO用于呼吸衰竭：呼吸系统评4分，心血管系统不评分
- ECMO用于心血管适应症：两个系统都评分

---

### 3. Cardiovascular（心血管系统）⭐最大更新

| 分数 | 标准 |
|-----|------|
| **0分** | MAP ≥70 mmHg，无血管活性药物 |
| **1分** | MAP <70 mmHg，无血管活性药物 |
| **2分** | **低剂量血管升压药**：<br>去甲肾上腺素+肾上腺素总和 ≤0.2 μg/kg/min<br>**或** 任何剂量的其他升压药/正性肌力药 |
| **3分** | **中剂量血管升压药**：<br>去甲肾+肾上腺素总和 >0.2 至 ≤0.4 μg/kg/min<br>**或** 低剂量血管升压药 + 其他升压药/正性肌力药 |
| **4分** | **高剂量血管升压药**：<br>去甲肾+肾上腺素总和 >0.4 μg/kg/min<br>**或** 中剂量血管升压药 + 其他升压药/正性肌力药<br>**或** 机械循环支持 |

**关键注释**：

**1. 血管活性药物计算规则**：
- 仅计入持续静脉输注≥1小时的药物
- 去甲肾上腺素剂量：按碱计算（非盐）
  - 1 mg碱 = 2 mg重酒石酸盐一水合物
  - 1 mg碱 = 1.89 mg无水重酒石酸盐
  - 1 mg碱 = 1.22 mg盐酸盐

**2. 多巴胺特殊评分**（如单独使用）：
- 2分: ≤20 μg/kg/min
- 3分: >20 至 ≤40 μg/kg/min
- 4分: >40 μg/kg/min

**3. 机械循环支持包括**：
- VA-ECMO（静脉-动脉体外膜肺氧合）
- IABP（主动脉内球囊反搏）
- LVAD（左心室辅助装置）
- 微轴流泵（Impella等）

**4. 替代评分（当血管活性药不可用时）**：
使用MAP分级：
- 0分: ≥70 mmHg
- 1分: 60-69 mmHg
- 2分: 50-59 mmHg
- 3分: 40-49 mmHg
- 4分: <40 mmHg

---

### 4. Liver（肝脏）

| 分数 | 标准（总胆红素） |
|-----|----------------|
| **0分** | ≤1.20 mg/dL (≤20.6 μmol/L) |
| **1分** | ≤3.0 mg/dL (≤51.3 μmol/L) |
| **2分** | ≤6.0 mg/dL (≤102.6 μmol/L) |
| **3分** | ≤12.0 mg/dL (≤205 μmol/L) |
| **4分** | >12.0 mg/dL (>205 μmol/L) |

**单位转换**：mg/dL × 17.104 = μmol/L

---

### 5. Kidney（肾脏）⭐重要更新

| 分数 | 标准 |
|-----|------|
| **0分** | 肌酐 ≤1.20 mg/dL (≤110 μmol/L) |
| **1分** | 肌酐 ≤2.0 mg/dL (≤170 μmol/L)<br>**或** 尿量 <0.5 mL/kg/h 持续6-12小时 |
| **2分** | 肌酐 ≤3.50 mg/dL (≤300 μmol/L)<br>**或** 尿量 <0.5 mL/kg/h ≥12小时 |
| **3分** | 肌酐 >3.50 mg/dL (>300 μmol/L)<br>**或** 尿量 <0.3 mL/kg/h ≥24小时<br>**或** 无尿（0 mL）≥12小时 |
| **4分** | 接受RRT（肾脏替代治疗）<br>**或** 符合RRT启动标准 |

**RRT启动标准**（用于未接受RRT的患者）：
- 肌酐 >1.2 mg/dL 或少尿（<0.3 mL/kg/h >6小时）
- **加上** 以下至少一项：
  - 血钾 ≥6.0 mmol/L
  - 代谢性酸中毒：pH ≤7.20 且碳酸氢盐 ≤12 mmol/L

**特殊情况**：
- 排除：仅为非肾脏原因接受RRT的患者（如毒物清除）
- 间歇性RRT：在非透析日也评4分，直至RRT终止

---

### 6. Hemostasis（凝血/止血）

| 分数 | 标准（血小板计数） |
|-----|------------------|
| **0分** | >150 × 10³/μL |
| **1分** | ≤150 × 10³/μL |
| **2分** | ≤100 × 10³/μL |
| **3分** | ≤80 × 10³/μL |
| **4分** | ≤50 × 10³/μL |

---

## 三、SOFA-2 vs SOFA-1 主要变化总结

### 变化1：呼吸系统
- **新增**：明确高级呼吸支持定义（包括HFNC、CPAP、BiPAP等）
- **阈值调整**：
  - SOFA-1的3分为PF≤200，SOFA-2改为≤150
  - 新增4分的ECMO指标

### 变化2：心血管系统（最大变化）
- **新增**：详细的血管活性药物剂量分级
- **新增**：去甲肾上腺素+肾上腺素联合剂量计算
- **新增**：机械循环支持评分
- **阈值重新分布**：
  - SOFA-1的2分几乎没有患者（0.9%）
  - SOFA-2的2分有8.9%患者（改善分布）

### 变化3：肾脏系统
- **阈值调整**：
  - 0分：从<1.2改为≤1.2
  - 其他阈值微调
- **新增**：明确RRT启动标准（代谢指标）
- **新增**：间歇RRT的评分规则

### 变化4：神经、肝脏、凝血
- **神经**：新增谵妄药物使用的评分规则
- **肝脏**：阈值从<1.2改为≤1.2
- **凝血**：无变化

### 变化5：术语更新
- Neurological → Brain
- Respiratory → Respiratory
- Cardiovascular → Cardiovascular
- Hepatic → Liver
- Renal → Kidney
- Coagulation → Hemostasis

---

## 四、数据采集时间窗口

### 标准时间窗口
- **ICU入院第1天**：入ICU后0-24小时内的最差值
- **后续天数**：每个日历日的最差值

### 缺失数据处理规则

**第1天（基线）**：
- 推荐：缺失值评0分
- 可能因具体目的而异（床旁使用、研究等）

**后续天数**：
- 推荐：**末次观测值前移（LOCF）**
- 理由：未测量提示病情稳定

---

## 五、特殊场景评分指南

### 场景1：治疗上限/资源限制
- **呼吸系统**：如无呼吸支持条件，仅用PF比值评分（可评3-4分）
- **心血管系统**：如无血管活性药，使用MAP分级

### 场景2：ECMO使用
- **呼吸适应症**：呼吸系统4分，心血管系统不因ECMO评分
- **心血管适应症**：两个系统都自动评分

### 场景3：镇静患者
- 使用镇静前最后GCS
- 如前值未知：评0分

### 场景4：慢性透析患者
- 如为ESRD且仅为慢性透析：**排除在SA-AKI研究外**
- 如急性恶化需额外RRT：纳入并评4分

---

## 六、MIMIC-IV数据库所需变量清单

### 1. Brain（神经）
```sql
-- 表：chartevents
-- itemid: GCS相关（223900, 223901, 220739）
-- 或motor_response, eye_opening, verbal_response

-- 表：prescriptions
-- 谵妄药物：haloperidol, quetiapine, olanzapine, risperidone
```

### 2. Respiratory（呼吸）
```sql
-- 表：chartevents, bg (血气)
-- PaO2 (itemid: 50821)
-- FiO2 (itemid: 223835, 50816)
-- SpO2 (itemid: 220277)

-- 表：ventilation, procedureevents
-- 机械通气类型：invasive, CPAP, BiPAP, HFNC
-- ECMO (itemid: 227719)
```

### 3. Cardiovascular（心血管）⭐关键
```sql
-- 表：chartevents
-- MAP (itemid: 220052, 220181, 225312)

-- 表：inputevents
-- 去甲肾上腺素 (itemid: 221906, 221907)
-- 肾上腺素 (itemid: 221289, 221662)
-- 多巴胺 (itemid: 221662)
-- 多巴酚丁胺 (itemid: 221653)
-- 去氧肾上腺素 (itemid: 221749)
-- 血管加压素 (itemid: 222315)

-- 表：procedureevents
-- ECMO, IABP, LVAD, Impella
```

### 4. Liver（肝脏）
```sql
-- 表：labevents
-- 总胆红素 (itemid: 50885)
```

### 5. Kidney（肾脏）
```sql
-- 表：labevents
-- 肌酐 (itemid: 50912)
-- 钾 (itemid: 50971)
-- pH (itemid: 50820)
-- 碳酸氢盐 (itemid: 50882)

-- 表：outputevents
-- 尿量 (itemid: 多个尿液输出项)

-- 表：procedureevents
-- RRT相关：CRRT, HD, CVVH, CVVHD, CVVHDF
```

### 6. Hemostasis（凝血）
```sql
-- 表：labevents
-- 血小板 (itemid: 51265)
```

### 7. 患者基础信息
```sql
-- 表：patients
-- subject_id, dob, gender

-- 表：admissions
-- hadm_id, admittime, dischtime, hospital_expire_flag

-- 表：icustays
-- stay_id, intime, outtime

-- 表：diagnoses_icd
-- 脓毒症相关ICD-10编码
```

---

## 七、关键实现难点和解决方案

### 难点1：血管活性药物剂量标准化
**问题**：
- 不同医院使用不同盐剂
- 需要统一换算为碱剂量
- 需要计算μg/kg/min

**解决方案**：
```python
# 去甲肾上腺素换算系数
NE_conversion = {
    'bitartrate': 2.0,      # 重酒石酸盐一水合物
    'tartrate': 1.89,       # 无水重酒石酸盐
    'hydrochloride': 1.22   # 盐酸盐
}

# 剂量计算
dose_mcg_kg_min = (rate_ml_hr * concentration_mg_ml * 1000) / (weight_kg * 60)
```

### 难点2：尿量计算
**问题**：
- 需要滑动时间窗口计算（6h、12h、24h）
- 需要患者体重
- 需要识别无尿状态

**解决方案**：
```python
# 滑动窗口尿量
def calculate_urine_output(df, window_hours):
    df['urine_ml_kg_h'] = (
        df.groupby('stay_id')['urineoutput']
        .rolling(window=f'{window_hours}H', min_periods=1)
        .sum() / (df['weight_kg'] * window_hours)
    )
```

### 难点3：高级呼吸支持识别
**问题**：
- 多种呼吸支持方式
- 需要区分有创/无创
- HFNC的识别

**解决方案**：
建立呼吸支持分类映射表

---

## 八、验证检查点

在实现SOFA-2计算后，应验证以下分布：

### 预期分布（基于JAMA文章）

**心血管系统**：
- SOFA-2的2分应约占8.9%（vs SOFA-1的0.9%）

**总分分布**：
- 中位数：3分（IQR 1-5）
- 与SOFA-1相比，SOFA-2低分段患者更多

**预测能力**：
- SOFA-2 AUROC: 0.79-0.81
- 应与SOFA-1相近或略优

---

## 九、参考文献

**主要文献**：
- Ranzani OT, Singer M, Salluh JIF, et al. Development and Validation of the Sequential Organ Failure Assessment (SOFA)-2 Score. *JAMA*. 2025. doi:10.1001/jama.2025.20516

**方法学文献**：
- Moreno R, Rhodes A, Ranzani O, et al. Rationale and Methodological Approach Underlying Development of the SOFA-2 Score. *JAMA Netw Open*. 2025. doi:10.1001/jamanetworkopen.2025.45040

---

## 十、快速查询表

### 常用阈值速查

| 系统 | 0分 | 1分 | 2分 | 3分 | 4分 |
|-----|-----|-----|-----|-----|-----|
| **Brain** | GCS 15 | GCS 13-14或谵妄药 | GCS 9-12 | GCS 6-8 | GCS 3-5 |
| **Resp** | PF>300 | PF≤300 | PF≤225 | PF≤150+通气 | PF≤75+通气或ECMO |
| **CV** | MAP≥70无药 | MAP<70无药 | NE+E≤0.2 | NE+E 0.2-0.4 | NE+E>0.4或机械 |
| **Liver** | Bili≤1.2 | Bili≤3 | Bili≤6 | Bili≤12 | Bili>12 |
| **Kidney** | Cr≤1.2 | Cr≤2或UO问题 | Cr≤3.5或UO<0.5 | Cr>3.5或UO<0.3 | RRT |
| **Hemo** | Plt>150 | Plt≤150 | Plt≤100 | Plt≤80 | Plt≤50 |

注：PF=PaO2:FiO2, CV=Cardiovascular, NE=去甲肾, E=肾上腺素, Bili=胆红素(mg/dL), Cr=肌酐(mg/dL), UO=尿量, Plt=血小板(×10³/μL)
