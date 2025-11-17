#!/bin/bash

# SOFA-2 SQL 升级验证脚本
# 验证升级后的sofa2.sql文件语法完整性

echo "=== SOFA-2 SQL 升级验证 ==="
echo "验证日期: $(date)"
echo

# 检查文件是否存在
SOFA_FILE="/mnt/f/SaAki_Sofa_benchmark/sofa2_sql/sofa2.sql"
BACKUP_FILE="/mnt/f/SaAki_Sofa_benchmark/sofa2_sql/sofa2_original_backup.sql"

if [ ! -f "$SOFA_FILE" ]; then
    echo "❌ 错误: 找不到升级后的sofa2.sql文件"
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    echo "❌ 错误: 找不到备份文件"
    exit 1
fi

echo "✅ 文件存在性检查通过"

# 检查文件大小变化
ORIGINAL_SIZE=$(wc -l < "$BACKUP_FILE")
UPGRADED_SIZE=$(wc -l < "$SOFA_FILE")
SIZE_DIFF=$((UPGRADED_SIZE - ORIGINAL_SIZE))

echo "📊 文件大小对比:"
echo "   原始文件: $ORIGINAL_SIZE 行"
echo "   升级文件: $UPGRADED_SIZE 行"
echo "   增加行数: $SIZE_DIFF 行"

if [ $SIZE_DIFF -gt 0 ]; then
    echo "✅ 文件大小增加 (预期行为)"
else
    echo "⚠️  警告: 文件大小未增加或减少了"
fi

echo

# 检查关键功能是否添加
echo "🔍 功能添加检查:"

# 检查Impella检测
if grep -q "224828\|224829" "$SOFA_FILE"; then
    echo "   ✅ Impella设备检测已添加"
else
    echo "   ❌ Impella设备检测未找到"
fi

# 检查RRT代谢标准
if grep -q "rrt_metabolic_criteria" "$SOFA_FILE"; then
    echo "   ✅ RRT代谢标准已添加"
else
    echo "   ❌ RRT代谢标准未找到"
fi

# 检查vasopressin
if grep -q "vasopressin" "$SOFA_FILE"; then
    echo "   ✅ Vasopressin检测已添加"
else
    echo "   ❌ Vasopressin检测未找到"
fi

# 检查phenylephrine
if grep -q "phenylephrine" "$SOFA_FILE"; then
    echo "   ✅ Phenylephrine检测已添加"
else
    echo "   ❌ Phenylephrine检测未找到"
fi

# 检查CPAP/BiPAP
if grep -q "cpap_bipap\|227287\|227288" "$SOFA_FILE"; then
    echo "   ✅ CPAP/BiPAP检测已添加"
else
    echo "   ❌ CPAP/BiPAP检测未找到"
fi

# 检查多时间窗尿量
if grep -q "uo_ml_kg_h_6h\|uo_ml_kg_h_12h" "$SOFA_FILE"; then
    echo "   ✅ 多时间窗尿量计算已添加"
else
    echo "   ❌ 多时间窗尿量计算未找到"
fi

echo

# 检查语法完整性
echo "🔧 语法完整性检查:"

# 计算括号匹配
OPEN_PARENS=$(grep -o '(' "$SOFA_FILE" | wc -l)
CLOSE_PARENS=$(grep -o ')' "$SOFA_FILE" | wc -l)

if [ $OPEN_PARENS -eq $CLOSE_PARENS ]; then
    echo "   ✅ 括号匹配: $OPEN_PARENS 对"
else
    echo "   ❌ 括号不匹配: 开括号 $OPEN_PARENS, 闭括号 $CLOSE_PARENS"
fi

# 检查CTE定义
CTE_COUNT=$(grep -c "^," "$SOFA_FILE")
echo "   ✅ CTE定义数量: $CTE_COUNT"

# 检查SELECT语句
SELECT_COUNT=$(grep -c "SELECT" "$SOFA_FILE")
echo "   ✅ SELECT语句数量: $SELECT_COUNT"

# 检查FROM语句
FROM_COUNT=$(grep -c "FROM" "$SOFA_FILE")
echo "   ✅ FROM语句数量: $FROM_COUNT"

echo

# 检查评分逻辑更新
echo "📈 评分逻辑检查:"

# 检查心血管评分是否包含新药物
if grep -q "vasopressin_rate\|phenylephrine_rate" "$SOFA_FILE"; then
    echo "   ✅ 心血管评分已更新包含新血管活性药物"
else
    echo "   ❌ 心血管评分未更新"
fi

# 检查肾脏评分是否使用RRT代谢标准
if grep -q "meets_rrt_criteria" "$SOFA_FILE"; then
    echo "   ✅ 肾脏评分已更新使用RRT代谢标准"
else
    echo "   ❌ 肾脏评分未更新"
fi

# 检查肾脏评分是否使用多时间窗
if grep -q "uo_ml_kg_h_6h\|uo_ml_kg_h_12h\|uo_ml_kg_h_24hr" "$SOFA_FILE"; then
    echo "   ✅ 肾脏评分已更新使用多时间窗尿量"
else
    echo "   ❌ 肾脏评分未使用多时间窗"
fi

echo

# 检查新增依赖
echo "📦 数据库依赖检查:"

if grep -q "mimiciv_icu.d_items" "$SOFA_FILE"; then
    echo "   ✅ 依赖 mimiciv_icu.d_items (设备标签匹配)"
else
    echo "   ❌ 未找到 mimiciv_icu.d_items 依赖"
fi

if grep -q "mimiciv_icu.inputevents" "$SOFA_FILE"; then
    echo "   ✅ 依赖 mimiciv_icu.inputevents (血管活性药物)"
else
    echo "   ❌ 未找到 mimiciv_icu.inputevents 依赖"
fi

echo

# 生成验证报告
echo "📋 验证总结:"
echo "   升级文件: sofa2.sql"
echo "   备份文件: sofa2_original_backup.sql"
echo "   文档文件: SOFA2_UPGRADE_NOTES.md"
echo

if [ -f "/mnt/f/SaAki_Sofa_benchmark/sofa2_sql/SOFA2_UPGRADE_NOTES.md" ]; then
    echo "   ✅ 升级文档已创建"
else
    echo "   ❌ 升级文档未找到"
fi

echo
echo "=== 验证完成 ==="
echo "建议: 在生产环境使用前，请在测试数据库中运行完整查询"