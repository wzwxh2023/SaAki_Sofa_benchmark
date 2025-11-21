# SOFA2 SQL Archive - 探索版本存档

**说明：** 本目录包含SOFA2评分系统开发过程中的所有探索版本和中间产物

---

## 📁 文件分类

### 🔧 核心优化版本 (已移至上级目录)
- `sofa2_optimized.sql` - **原始核心优化版本** ✅
- `sofa2_optimized_fixed_working.sql` - **修复后的工作版本** ✅
- `step1.sql, step2.sql, step3.sql, step5.sql` - **最终拆分版本** ✅
- `sofa2_table_separation.sql` - **数据分离脚本** ✅

### 📦 本目录存档的探索版本

#### 性能优化相关
- `sofa2_optimized_chunk.sql` - 分块处理版本
- `sofa2_optimized_v2.sql` - 优化版本2
- `sofa2_optimized_v3.sql` - 优化版本3
- `sofa2_optimized_safe.sql` - 安全版本
- `sofa2_optimized_batch.sql` - 批处理版本
- `sofa2_optimized_fixed.sql` - 修复版本（非工作版本）

#### 数据预处理版本
- `sofa2_preprocessing_optimized.sql` - 预处理优化版本
- `sofa2_preprocessing_enhanced.sql` - 增强预处理版本
- `sofa2_stage1_basic_preprocessing.sql` - 基础预处理版本

#### 测试和验证版本
- `sofa2_test_100.sql` - 100例患者测试版本
- `sofa2_simple_success.sql` - 简化成功版本
- `sofa2_simple_performance_test.sql` - 性能测试版本
- `sofa2_complete_optimized_test.sql` - 完整优化测试版本

#### 最终运行版本
- `sofa2_final_optimized.sql` - 最终优化版本
- `sofa2_final_run.sql` - 最终运行版本
- `sofa2_complete_fixed_review.sql` - 完整修复审查版本

#### 修复和调试版本
- `sofa2_fixed.sql` - 基础修复版本
- `sofa2_complete_fixed_review.sql` - 完整修复审查版本

#### 其他相关脚本
- `first_day_sofa2.sql` - 首日SOFA2版本
- `sepsis3_sofa2.sql` - Sepsis 3.0 SOFA2版本
- `00_helper_views.sql` - 辅助视图
- `sedation_optimization.sql` - 镇静优化版本
- `drug_mapping_optimized.sql` - 药物映射优化版本

#### 辅助工具
- `create_stored_procedure.sql` - 存储过程创建脚本
- `verify_itemid_count.sql` - ItemID计数验证
- `data_size_analysis.sql` - 数据大小分析

#### 平台特定版本
- `sofa2_windows_simple.sql` - Windows简化版本
- `sofa2_windows_power.ps1` - Windows PowerShell脚本

---

## 🎯 版本演进路径

```
原始版本 → sofa2_optimized.sql (核心优化)
         ↓
         → sofa2_optimized_fixed_working.sql (修复版本)
         ↓
         → step1-5.sql (拆分版本 - 最终生产版本)
```

## 📝 使用说明

1. **生产环境：** 使用上级目录的step1-5.sql系列脚本
2. **研究参考：** `sofa2_optimized_fixed_working.sql`作为完整脚本参考
3. **历史追溯：** 本目录包含所有中间版本，用于理解开发过程

---

**存档时间：** 2025-11-21
**存档原因：** 整理项目结构，保留核心版本，存档探索过程