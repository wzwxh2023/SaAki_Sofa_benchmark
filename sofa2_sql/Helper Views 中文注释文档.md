下面为你生成一个**独立的 Markdown 文件**，其中包含对你提供的 SOFA‑2 helper 脚本的**逐模块中文解读与注释**。

---

# SOFA‑2 Helper Views 中文注释文档
本文件为 SOFA‑2（Sequential Organ Failure Assessment‑2）计算中所需的辅助视图（helper views）提供逐模块的中文解释与实现逻辑说明。  
对应的原始脚本包含五大部分：  
1. 谵妄药物  
2. 高级呼吸支持  
3. 机械循环支持  
4. RRT 与代谢性指标  
5. 补充血管活性药物  
后附尿量与体重计算部分。

---

## SECTION 1：谵妄（Delirium）药物  
本模块用于识别 ICU 患者是否正在使用常见的“治疗谵妄药物”。  
在 SOFA‑2 中，只要使用过这些药物，神经系统评分（Brain component）**至少为 1 分**。

### 识别的药物包括  
- Haloperidol（Haldol）  
- Quetiapine（Seroquel）  
- Olanzapine（Zyprexa）  
- Risperidone（Risperdal）  

### 数据来源  
`mimiciv_hosp.prescriptions`（住院处方数据库）

### 使用方法  
该 CTE 会标记：  
- stay_id（ICU 住院）  
- 药物使用时间窗  
- 药名  
- 是否正在使用谵妄药物（1 为是）

该 CTE 可用于 SOFA‑2 主查询中，为神经系统评分提供最低分保障。

---

## SECTION 2：高级呼吸支持（Advanced Respiratory Support）  
用于 SOFA‑2 呼吸系统评分（Respiratory component）。

### 高级呼吸支持包括  
- HFNC（高流量鼻导管）  
- CPAP（持续气道正压）  
- BiPAP（双水平气道正压）  
- NIV（非侵入性通气）  
- IMV（侵入性机械通气）  
- 长期家庭通气（Long‑term home ventilation）

### 数据来源  
主要来自以下两个地方：

#### 1. mimiciv_derived.ventilation（结构化通气事件）
`ventilation_status` 包括：  
- InvasiveVent  
- NonInvasiveVent  
- HFNC  
- Tracheostomy  

这些被归类为 IMV / NIV / HFNC。

#### 2. chartevents（检测 CPAP / BiPAP）
利用 itemid：  
- 227287：CPAP  
- 227288：BiPAP  

这些记录属于 monitor 参数而非 ventilation 表，因此需要单独处理。

---

## SECTION 3：机械循环支持（Mechanical Circulatory Support）  
属于 SOFA‑2 心血管评分（Cardiovascular component），如果患者正在使用这些设备，则心血管评分自动为 4 分（最高分）。

### 包含的设备  
- ECMO（体外膜氧合）  
- IABP（主动脉内球囊反搏）  
- LVAD（左心室辅助装置）  
- Impella（微轴流泵心室辅助装置）

### 检测逻辑  
#### 1. 来自 chartevents 的结构化 itemid  
ECMO itemid：  
- 228001  
- 229270  
- 229272 (Flow/Alarm)  

IABP itemid：  
- 228000  
- 224797  
- 224798  

Impella itemid：  
- 224828  
- 224829  

#### 2. 使用 value 字段（自由文本）模糊匹配  
为了捕获未被结构化 itemid 记录的设备事件：  
```
%ecmo%
%iabp%
%impella%
%lvad%
```
例：  
“ECMO started”, “Impella removed”, “LVAD running” 等。

### 扩展：procedureevents  
部分 Impella/ECMO 插管操作在 procedureevents 中出现，因此提供可选 CTE 用于进一步补充。

---

## SECTION 4：RRT（肾替代治疗）及代谢性标准  
用于 SOFA‑2 肾脏评分（Kidney component）。

### 评分 4 分的条件  
患者满足下列之一：

1. 正在接受 RRT（透析）  
2. 满足 RRT 启动标准：  
   - 肌酐 > 1.2 mg/dL  
   - 且同时满足以下任一：  
     - K+ ≥ 6.0 mmol/L  
     - pH ≤ 7.2 且 HCO3− ≤ 12 mmol/L  

### 数据来源  
- mimiciv_derived.rrt：是否正在透析  
- mimiciv_derived.chemistry：肌酐、钾  
- mimiciv_derived.bg：动脉血气（pH / HCO3）

该模块提供一个 CTE 判断患者是否达到“需要 RRT”条件。

---

## SECTION 5：额外血管活性药物（补充类）  
用于补全 cardiovascular scoring（循环系统评分）中常规血管活性药物之外的项目。

### 补充药物  
- Vasopressin（加压素）  
- Phenylephrine（苯肾上腺素）

### 数据来源  
`inputevents`  
- Vasopressin itemid：222315  
- Phenylephrine itemid：221749（会进一步按体重换算成 mcg/kg/min）

这些药物用于更精确评估血管活性药使用强度。

---

## SECTION 6：体重标准化尿量（ml/kg/h）  
用于 SOFA‑2 肾脏评分的尿量部分。

### 计算目标  
得到以下时间窗的体重标准化尿量：  
- 6 小时平均  
- 12 小时平均  
- 24 小时平均  

### 数据来源  
- mimiciv_derived.urine_output  
- mimiciv_derived.first_day_weight  

通过窗口函数（window function）计算最近 N 小时的尿量并除以体重。

---

## Validation（验证查询）  
包含一些基础 prevalence 检查，如：  
- 谵妄药物使用率  
- 不同 ventilation_status 的数量  
- ECMO/IABP 患者数量  

用于快速确认数据质量及设备记录情况。

---

# 总结  
本文件对 SOFA‑2 的辅助模块进行了全面中文解释，包括药物、呼吸支持、机械循环支持、RRT 与代谢标准、血管活性药物及尿量计算。  
这些模块构成 SOFA‑2 算分系统的关键基础结构，可直接嵌入主查询脚本中用于 ICU 器官功能衰竭评分。

如果你需要，我还能帮你：  
- 拼接成完整的 SOFA‑2 SQL  
- 做成可在 PostgreSQL 或 BigQuery 上运行的最终版本  
- 生成流程图 / 数据流图（Markdown 或 mermaid）  
任你选择。
