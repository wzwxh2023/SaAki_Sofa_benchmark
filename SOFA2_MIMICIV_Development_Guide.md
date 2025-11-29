# SOFA-2 评分在 MIMIC-IV 中的实现指南

> 基于 JAMA 2024 发布的 SOFA-2 评分标准，在 MIMIC-IV 数据库中的完整实现方案

---

## 目录

1. [概述](#1-概述)
2. [整体架构](#2-整体架构)
3. [各器官系统实现细节](#3-各器官系统实现细节)
4. [关键设计决策](#4-关键设计决策)
5. [数据限制与处理策略](#5-数据限制与处理策略)
6. [脚本执行顺序](#6-脚本执行顺序)
7. [验证与质量控制](#7-验证与质量控制)

---

## 1. 概述

### 1.1 SOFA-2 评分标准

SOFA-2（Sequential Organ Failure Assessment 2）是2024年发布的器官功能障碍评分系统更新版本，评估6个器官系统：

| 器官系统 | 评分范围 | 主要指标 |
|----------|----------|----------|
| 脑/神经 (Brain) | 0-4 | GCS评分、谵妄用药 |
| 呼吸 (Respiratory) | 0-4 | PaO₂/FiO₂、SpO₂/FiO₂、高级呼吸支持 |
| 心血管 (Cardiovascular) | 0-4 | MAP、血管活性药物、机械循环支持 |
| 肝脏 (Liver) | 0-4 | 总胆红素 |
| 肾脏 (Kidney) | 0-4 | 肌酐、尿量、RRT |
| 凝血 (Hemostasis) | 0-4 | 血小板计数 |

**总分范围**：0-24分（各器官系统24小时内最差值求和）

### 1.2 实现目标

- 基于 MIMIC-IV 数据库完整实现 SOFA-2 评分
- 生成每小时评分（hourly scores）
- 计算24小时滚动窗口最差评分（rolling worst scores）
- 确保评分标准的准确复现

---

## 2. 整体架构

### 2.1 脚本结构

```
step1.sql  →  step2.sql  →  step3.sql  →  step5.sql
  环境配置      中间表生成     小时评分计算    24小时汇总
```

### 2.2 数据流转

```
┌─────────────────────────────────────────────────────────────────┐
│                        MIMIC-IV 原始表                          │
│  chartevents, inputevents, labevents, prescriptions, etc.      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Step 2: 中间表 (Stage1)                      │
│  sofa2_stage1_brain, sofa2_stage1_mech, sofa2_stage1_urine...  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                 Step 3: sofa2_hourly_raw                        │
│            每小时各器官系统的原始评分 (0-4分)                    │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                   Step 5: sofa2_scores                          │
│              24小时滚动窗口最差评分 + 总分                       │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 生成的表清单

| 表名 | 类型 | 说明 |
|------|------|------|
| `sofa2_stage1_sedation` | UNLOGGED | 镇静药物使用区间 |
| `sofa2_stage1_delirium` | UNLOGGED | 谵妄药物使用（小时网格） |
| `sofa2_stage1_brain` | UNLOGGED | GCS评分（区间表，含LOCF） |
| `sofa2_stage1_resp_support` | UNLOGGED | 高级呼吸支持状态 |
| `sofa2_stage1_mech` | UNLOGGED | 机械循环支持/ECMO |
| `sofa2_stage1_oxygen` | UNLOGGED | 氧合指数 (PF/SF) |
| `sofa2_stage1_kidney_labs` | UNLOGGED | 肾脏实验室指标 |
| `sofa2_stage1_rrt` | UNLOGGED | RRT状态 |
| `sofa2_stage1_urine` | UNLOGGED | 尿量滑动窗口 |
| `sofa2_stage1_coag` | UNLOGGED | 血小板计数 |
| `sofa2_stage1_liver` | UNLOGGED | 胆红素 |
| `sofa2_hourly_raw` | TABLE | 每小时原始评分 |
| `sofa2_scores` | TABLE | 最终24小时评分 |

---

## 3. 各器官系统实现细节

### 3.1 脑/神经系统 (Brain)

#### 评分标准

| 分数 | 标准 |
|------|------|
| 0 | GCS = 15 |
| 1 | GCS 13-14，或使用谵妄药物（即使GCS=15） |
| 2 | GCS 9-12 |
| 3 | GCS 6-8 |
| 4 | GCS 3-5 |

#### 实现要点

**1. 镇静处理 (LOCF回溯)**

```sql
-- 镇静药物列表
222168  -- Propofol (丙泊酚)
221668  -- Midazolam (咪达唑仑)
229420  -- Dexmedetomidine (右美托咪定)
225150  -- Dexmedetomidine (次要ID)
221385  -- Lorazepam (劳拉西泮)
221712  -- Ketamine (氯胺酮)
221756  -- Etomidate (依托咪酯)
225156  -- Pentobarbital (戊巴比妥)
```

- **设计决策**：不设置药物洗脱期，直接使用输注的starttime和endtime
- **LOCF机制**：镇静期间使用镇静前最后一次清醒时的GCS评分

**2. 插管患者处理**

- 当 `gcs_unable = 1` 时，强制使用 Motor GCS 评分
- Motor GCS 映射：6→0分, 5→1分, 4→2分, 3→3分, ≤2→4分

**3. 谵妄药物**

```sql
-- 谵妄药物列表（模糊匹配）
haloperidol, quetiapine, olanzapine, risperidone, 
ziprasidone, clozapine, aripiprazole
```

- **特殊规则**：使用谵妄药物且GCS=15时，记1分（非0分）

---

### 3.2 呼吸系统 (Respiratory)

#### 评分标准

| 分数 | PaO₂/FiO₂ | SpO₂/FiO₂ (备选) | 条件 |
|------|-----------|------------------|------|
| 0 | >300 | >300 | - |
| 1 | ≤300 | ≤300 | - |
| 2 | ≤225 | ≤250 | - |
| 3 | ≤150 | ≤200 | 需高级呼吸支持 |
| 4 | ≤75 或 ECMO | ≤120 或 ECMO | 需高级呼吸支持 |

#### 实现要点

**1. SF比值使用条件**

- 仅当 PaO₂ 不可用 **且** SpO₂ < 98% 时使用 SF 比值

**2. 高级呼吸支持定义**

```sql
ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'Tracheostomy', 'HFNC')
```

- 包括：HFNC、CPAP、BiPAP、NIV、有创机械通气

**3. 评分上限规则**

- 未接受高级呼吸支持的患者，呼吸评分最高只能得2分
- 代码通过 `AND rs.with_resp_support = 1` 条件实现

**4. ECMO处理**

- 任何类型ECMO → 呼吸系统4分

**5. 时间窗口**

- PaO₂、SpO₂、FiO₂ 均使用1小时窗口精确匹配
- 24小时滚动MAX确保不丢失异常值

---

### 3.3 心血管系统 (Cardiovascular)

#### 评分标准

| 分数 | 条件 |
|------|------|
| 0 | MAP ≥70 mmHg，无血管活性药 |
| 1 | MAP <70 mmHg，无血管活性药 |
| 2 | NE+Epi ≤0.2 μg/kg/min，或任何剂量其他血管活性药 |
| 3 | NE+Epi >0.2-0.4 μg/kg/min，或低剂量+其他药物 |
| 4 | NE+Epi >0.4 μg/kg/min，或中剂量+其他药物，或机械支持 |

#### 实现要点

**1. 血管活性药持续时间规则**

```sql
AND co.endtime >= va.starttime + INTERVAL '1 HOUR'  -- 持续≥1小时才计分
```

**2. 多巴胺单独使用评分**

- ≤20 μg/kg/min → 2分
- >20-40 μg/kg/min → 3分
- >40 μg/kg/min → 4分

**3. 纯MAP评分（无血管活性药时）**

- ≥70 → 0分
- 60-69 → 1分
- 50-59 → 2分
- 40-49 → 3分
- <40 → 4分

**4. ECMO分类处理**

| ECMO类型 | Circuit Configuration | 心血管评分 |
|----------|----------------------|------------|
| VV-ECMO | 'VV' | 按其他指标评分 |
| VA-ECMO | 'VA' | **4分** |
| VAV-ECMO | 'VAV' | **4分** |
| 未知 | '---' 或空 | **4分**（保守处理） |

```sql
-- 核心判断逻辑
WHEN COALESCE(has_ecmo, 0) = 1 AND COALESCE(has_vv_ecmo, 0) = 0 THEN 4
```

**5. 其他机械循环支持**

- IABP、Impella、LVAD、RVAD 等 → 4分

---

### 3.4 肝脏系统 (Liver)

#### 评分标准

| 分数 | 总胆红素 (mg/dL) |
|------|------------------|
| 0 | ≤1.2 |
| 1 | >1.2 - ≤3.0 |
| 2 | >3.0 - ≤6.0 |
| 3 | >6.0 - ≤12.0 |
| 4 | >12.0 |

#### 实现要点

- **数据源**：`mimiciv_derived.enzyme` (bilirubin_total)
- **时间窗口**：48小时（基于数据分布，覆盖90%+检验间隔）
- **连接方式**：通过 `hadm_id` 限制在当前住院
- **聚合函数**：`MAX(bilirubin_total)` 取最差值

---

### 3.5 肾脏系统 (Kidney)

#### 评分标准

| 分数 | 肌酐 (mg/dL) | 尿量 | 其他 |
|------|--------------|------|------|
| 0 | ≤1.2 | - | - |
| 1 | >1.2 - ≤2.0 | <0.5 mL/kg/h 持续6-12h | - |
| 2 | >2.0 - ≤3.5 | <0.5 mL/kg/h 持续≥12h | - |
| 3 | >3.5 | <0.3 mL/kg/h 持续≥24h 或无尿≥12h | - |
| 4 | - | - | RRT 或满足RRT标准 |

#### 实现要点

**1. 体重获取（五级兜底，100%覆盖）**

| 优先级 | 来源 | 覆盖率 |
|--------|------|--------|
| 1 | `weight_admit` | ~92.5% |
| 2 | `weight` (首日均值) | ~96.5% |
| 3 | `weight_full_avg` (全程均值) | ~96.5% |
| 4 | `chartevents` 原始记录 | ~98.1% |
| 5 | 性别中位数 (F:70kg, M:83.3kg) | **100%** |

**2. 尿量滑动窗口**

```sql
WINDOW 
    w6  AS (ROWS BETWEEN 5 PRECEDING AND CURRENT ROW),   -- 6小时
    w12 AS (ROWS BETWEEN 11 PRECEDING AND CURRENT ROW),  -- 12小时
    w24 AS (ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)   -- 24小时
```

**3. 动态分母**

- 使用 `COUNT(*)` 作为实际小时数，解决短住院问题
- 尿量率 = `uo_sum / weight / cnt`

**4. Virtual RRT（满足RRT标准但未接受）**

- 条件：(Cr>1.2 或 少尿) **且** (高钾≥6.0 或 代谢性酸中毒)

**5. 无尿定义**

- 12小时尿量 < 5mL（排除误记录和极小值）

---

### 3.6 凝血系统 (Hemostasis)

#### 评分标准

| 分数 | 血小板 (×10³/μL) |
|------|------------------|
| 0 | >150 |
| 1 | ≤150 |
| 2 | ≤100 |
| 3 | ≤80 |
| 4 | ≤50 |

#### 实现要点

- **数据源**：`mimiciv_derived.complete_blood_count`
- **时间窗口**：48小时（覆盖90%+检验间隔）
- **连接方式**：通过 `hadm_id` 限制在当前住院
- **聚合函数**：`MIN(platelet)` 取最差值

---

## 4. 关键设计决策

### 4.1 时间窗口策略

| 数据类型 | 窗口设置 | 理由 |
|----------|----------|------|
| SpO₂ / PaO₂ / FiO₂ | 1小时 | 保持时间匹配，避免计算错误 |
| RRT状态 | 1小时 | 实时状态判断 |
| 尿量 | 滑动窗口6/12/24h | SOFA标准要求 |
| 肌酐/电解质 | 1小时 | 由24小时MAX兜底 |
| 血小板/胆红素 | 48小时 | 检验频率低，需要回溯 |

### 4.2 ECMO双重评分

- **呼吸系统**：所有ECMO → 4分
- **心血管系统**：仅VA/VAV/未知ECMO → 4分；明确VV → 按其他指标
- **数据来源**：`itemid = 229268` (Circuit Configuration)

### 4.3 24小时滚动窗口

```sql
WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW)
```

- 各器官系统独立取24小时内最差值
- 最终总分 = 各器官最差值之和

### 4.4 表结构选择

| 表类型 | 适用场景 | 示例 |
|--------|----------|------|
| 区间表 | 判断时间点状态 | sedation, brain |
| 小时网格 | 直接参与评分计算 | delirium, oxygen, urine |

---

## 5. 数据限制与处理策略

### 5.1 已知限制

| 限制 | SOFA-2标准要求 | 处理策略 |
|------|----------------|----------|
| 无法区分吸痰后波动 | 操作后1小时内不计入 | 接受限制，文档说明 |
| ECMO类型不完整 | 区分VV/VA | 未知类型保守处理为VA |
| 体重缺失 | 计算尿量率需要 | 五级兜底，100%覆盖 |
| 实验室检查稀疏 | 每小时评分 | 48小时窗口+24小时MAX |

### 5.2 数据质量保障

- 所有数值过滤合理范围（如体重20-300kg）
- 单位转换处理（如lbs→kg）
- 通过 `hadm_id` 限制跨住院匹配

---

## 6. 脚本执行顺序

```bash
# 1. 环境配置与清理
psql -f step1.sql

# 2. 生成中间表
psql -f step2.sql

# 3. 计算每小时评分
psql -f step3.sql

# 4. 计算24小时滚动评分
psql -f step5.sql
```

### 执行时间预估

| 脚本 | 预估时间 | 说明 |
|------|----------|------|
| step1 | <1分钟 | 环境配置 |
| step2 | 10-30分钟 | 中间表生成（最耗时） |
| step3 | 5-15分钟 | 评分计算 |
| step5 | 2-5分钟 | 滚动窗口汇总 |

---

## 7. 验证与质量控制

### 7.1 数据完整性检查

```sql
-- 检查评分分布
SELECT 
    brain, respiratory, cardiovascular, liver, kidney, hemostasis,
    COUNT(*) as cnt
FROM mimiciv_derived.sofa2_scores
GROUP BY 1,2,3,4,5,6
ORDER BY cnt DESC
LIMIT 20;

-- 检查总分分布
SELECT 
    sofa2_total,
    COUNT(*) as cnt,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) as pct
FROM mimiciv_derived.sofa2_scores
GROUP BY 1
ORDER BY 1;
```

### 7.2 边界值验证

```sql
-- 检查是否有超出范围的评分
SELECT 
    MIN(brain) as min_brain, MAX(brain) as max_brain,
    MIN(respiratory) as min_resp, MAX(respiratory) as max_resp,
    MIN(cardiovascular) as min_cv, MAX(cardiovascular) as max_cv,
    MIN(liver) as min_liver, MAX(liver) as max_liver,
    MIN(kidney) as min_kidney, MAX(kidney) as max_kidney,
    MIN(hemostasis) as min_hemo, MAX(hemostasis) as max_hemo,
    MIN(sofa2_total) as min_total, MAX(sofa2_total) as max_total
FROM mimiciv_derived.sofa2_scores;
```

### 7.3 覆盖率检查

```sql
-- 检查各组件数据覆盖率
SELECT 
    COUNT(*) as total_hours,
    COUNT(*) FILTER (WHERE brain_score > 0) as has_brain,
    COUNT(*) FILTER (WHERE respiratory_score > 0) as has_resp,
    COUNT(*) FILTER (WHERE cardiovascular_score > 0) as has_cv,
    COUNT(*) FILTER (WHERE liver_score > 0) as has_liver,
    COUNT(*) FILTER (WHERE kidney_score > 0) as has_kidney,
    COUNT(*) FILTER (WHERE hemostasis_score > 0) as has_hemo
FROM mimiciv_derived.sofa2_hourly_raw;
```

---

## 附录

### A. ItemID 参考表

#### A.1 镇静药物
| ItemID | 药物名称 |
|--------|----------|
| 222168 | Propofol |
| 221668 | Midazolam |
| 229420 | Dexmedetomidine |
| 225150 | Dexmedetomidine |
| 221385 | Lorazepam |
| 221712 | Ketamine |
| 221756 | Etomidate |
| 225156 | Pentobarbital |

#### A.2 ECMO相关
| ItemID | 说明 |
|--------|------|
| 229268 | Circuit Configuration (VV/VA/VAV) |
| 224660 | ECMO (General) |
| 229270 | Flow (ECMO) |
| 229277 | Speed (ECMO) |
| 229280 | FiO2 (ECMO) |

#### A.3 体重相关
| ItemID | 说明 | 单位 |
|--------|------|------|
| 224639 | Daily Weight | kg |
| 226512 | Admission Weight (Kg) | kg |
| 226531 | Admission Weight (lbs.) | lbs → ×0.453592 |

### B. 版本历史

| 版本 | 日期 | 修改内容 |
|------|------|----------|
| 1.0 | 2025-XX-XX | 初始版本 |

---

## 参考文献

1. SOFA-2 评分标准原文 (JAMA 2024)
2. MIMIC-IV 官方文档: https://mimic.mit.edu/docs/iv/
3. MIMIC Code Repository: https://github.com/MIT-LCP/mimic-code

---

*文档生成日期: 2025年*
