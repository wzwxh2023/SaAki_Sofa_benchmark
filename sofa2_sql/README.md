# SOFA2评分系统 - 生产版本

**项目状态：** ✅ 生产就绪 (2025-11-21最终版本)
**数据库：** MIMIC-IV v2.2 + PostgreSQL
**性能：** 优化完成，支持大规模临床研究

---

## 📋 项目概述

SOFA2评分系统是30年来Sequential Organ Failure Assessment评分的首次重大更新。本项目提供了完整、高效的MIMIC-IV数据库SOFA2评分计算方案。

### 🎯 核心改进
1. **心血管系统评分优化** - 去甲肾上腺素+肾上腺素联合剂量计算
2. **呼吸阈值更新** - 新的PaO2/FiO2临界值，支持高级呼吸支持
3. **肾脏评分增强** - RRT标准+代谢指标综合评估
4. **谵妄整合** - 神经系统评分纳入谵妄药物
5. **术语更新** - "Brain"替代"CNS"，"Hemostasis"替代"Coagulation"

---

## 📁 当前文件结构 (生产版本)

```
sofa2_sql/
├── README.md                          # 本文件 - 项目说明
├── VERSION_COMPARISON_REPORT.md       # 版本对比分析报告
├── step1.sql                          # 环境配置和清理
├── step2.sql                          # 组件中间表创建
├── step3.sql                          # 每小时原始评分计算
├── step5.sql                          # 24小时滑动窗口最终评分
├── sofa2_optimized.sql                # V1: 原始优化版本 (参考用)
├── sofa2_optimized_fixed.sql          # V2: 修复版本 (核心优化逻辑) ⭐
├── sofa2_optimized_fixed_working.sql  # V3: 工作版本 (简洁稳定)
├── sofa2_table_separation.sql         # ICU/ICU前数据分离脚本
├── archive/                           # 探索版本存档目录
│   └── ARCHIVE_README.md              # 存档文件说明
├── validation/                        # 验证脚本目录
├── tests/                             # 测试脚本目录
├── Patient_Coverage_Analysis_Report.md # 患者覆盖率分析报告
├── SOFA2_Data_Quality_Analysis_Report.md # 数据质量分析报告
└── [其他文档...]                       # 项目过程文档
```

---

## 🚀 生产环境使用指南

### 方式1: 分步执行 (推荐)
```bash
# 顺序执行所有步骤
psql -h host -U user -d mimiciv -f step1.sql
psql -h host -U user -d mimiciv -f step2.sql
psql -h host -U user -d mimiciv -f step3.sql
psql -h host -U user -d mimiciv -f step5.sql
```

### 方式2: 完整脚本执行
```bash
# 选项A: V2版本 (性能优化版本)
psql -h host -U user -d mimiciv -f sofa2_optimized_fixed.sql

# 选项B: V3版本 (简洁稳定版本)
psql -h host -U user -d mimiciv -f sofa2_optimized_fixed_working.sql
```

### 方式3: 数据分离 (高级分析)
```bash
# 创建分离的ICU和ICU前评分表
psql -h host -U user -d mimiciv -f sofa2_table_separation.sql
```

---

## 📊 数据表说明

### 主要输出表
- **`mimiciv_derived.sofa2_scores`** - 完整SOFA2评分表 (10,485,609条记录)
- **`mimiciv_derived.sofa2_icu_scores`** - ICU内评分表 (8,219,121条记录)
- **`mimiciv_derived.sofa2_preicu_scores`** - ICU前评分表 (135,096条记录)

### 覆盖率统计
- **ICU患者覆盖率：** 99.99% (65,365/65,366)
- **ICU住院覆盖率：** 99.98% (94,437/94,458)
- **排除患者：** 21名极短住院患者 (平均6.7小时)

---

## 🔧 SOFA2评分标准详解

### 1. 神经系统 (Brain) - 更新
| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| 谵妄药物 | 不考虑 | +1分 (使用氟哌啶醇、喹硫平等) |
| GCS阈值 | 相同 | 相同 (无变化) |

### 2. 呼吸系统 (Respiratory) - 重大更新
| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| 4分 | PF<100+呼吸机 | PF≤75+高级支持 **或 ECMO** |
| 3分 | PF<200+呼吸机 | PF≤150+高级支持 |
| 2分 | PF<300 | PF≤225 |
| 1分 | PF<400 | PF≤300 |

**高级呼吸支持** = HFNC、CPAP、BiPAP、NIV、IMV

### 3. 心血管系统 (Cardiovascular) - 最大变化
| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| 4分 | 多巴胺>15 或 肾上腺素>0.1 或 去甲>0.1 | **NE+Epi>0.4** 或 机械支持 |
| 3分 | 多巴胺>5 或 肾上≤0.1 或 去甲≤0.1 | **NE+Epi 0.2-0.4** 或 低剂量+其他 |
| 2分 | 任何多巴胺 或 任何多巴酚丁胺 | **NE+Epi≤0.2** 或 其他血管活性药 |

### 4. 肾脏系统 (Kidney) - 重要更新
| 评分 | SOFA-1 | SOFA-2 |
|------|--------|--------|
| 4分 | Cr≥5.0 或 尿量<200ml/24h | **RRT或符合RRT标准** |
| 3分 | Cr 3.5-5.0 或 尿量<500ml/24h | Cr>3.5 或 **尿量<0.3ml/kg/h≥24h** |
| 2分 | Cr 2.0-3.5 | Cr≤3.5 或 **尿量<0.5ml/kg/h≥12h** |
| 1分 | Cr 1.2-2.0 | Cr≤2.0 或 **尿量<0.5ml/kg/h 6-12h** |

---

## ⚠️ 重要注意事项

### 数据质量控制
1. **心率数据要求：** SOFA2计算需要连续生命体征监测支持
2. **24小时滑动窗口：** 确保评分稳定性和临床可靠性
3. **自动排除机制：** 极短住院患者自动排除(21/94,458, 0.02%)

### 特殊评分规则
- **ECO患者：** 呼吸ECMO时呼吸系统=4分，心血管不评分
- **多巴胺特殊评分：** 单独使用时的特殊阈值
- **药物盐基转换：** 需要转换为base计算

---

## 📈 性能指标

### 计算性能
- **完整数据库处理时间：** ~2-3小时 (取决于硬件)
- **内存使用：** 优化后支持大规模数据
- **并行处理：** 支持24并行worker

### 数据质量
- **数据纯度：** 99.9% (移除20.3%虚拟框架数据)
- **时间框架：** ICU前24小时到ICU出院
- **滑动窗口：** 24小时最差评分算法

---

## 📋 版本选择指南

### 核心版本对比
| 版本 | 文件大小 | 特点 | 适用场景 |
|------|----------|------|----------|
| **V1** `sofa2_optimized.sql` | 46K (1,144行) | 原始优化版本 | 了解设计思路 |
| **V2** `sofa2_optimized_fixed.sql` | 41K (1,079行) | 性能优化架构 | 需要临时表优化时参考 |
| **V3** `sofa2_optimized_fixed_working.sql` | 21K (391行) | 简洁稳定版 | 快速一键执行 |

### 推荐使用场景
1. **生产研究：** step1-5.sql (推荐)
2. **快速测试：** V3 `sofa2_optimized_fixed_working.sql`
3. **性能调优：** V2 `sofa2_optimized_fixed.sql`
4. **学习理解：** V1 `sofa2_optimized.sql`

### 详细版本分析
完整的版本对比分析请参考：`VERSION_COMPARISON_REPORT.md`

---

## 📚 参考资料

1. **Ranzani OT, et al.** Development and Validation of the Sequential Organ Failure Assessment (SOFA)-2 Score. *JAMA*. 2025.
2. **Moreno R, et al.** Rationale and Methodological Approach Underlying Development of the SOFA-2 Score. *JAMA Netw Open*. 2025.
3. **Original SOFA:** Vincent JL, et al. The SOFA score to describe organ dysfunction/failure. *Intensive Care Med*. 1996.

---

## 📧 项目信息

**最后更新：** 2025-11-21
**版本：** v1.0.0 生产就绪
**数据库：** MIMIC-IV v2.2
**项目状态：** 完成并通过验证

**相关文档：**
- SOFA2标准详解: `/mnt/f/SaAki_Sofa_benchmark/SOFA2_评分标准详解.md`
- 研究方案: `/mnt/f/SaAki_Sofa_benchmark/研究方案_SOFA2_SA-AKI_Letter.md`
- 患者覆盖率分析: `Patient_Coverage_Analysis_Report.md`
- 数据质量分析: `SOFA2_Data_Quality_Analysis_Report.md`