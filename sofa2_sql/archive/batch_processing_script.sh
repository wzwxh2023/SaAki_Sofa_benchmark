#!/bin/bash
# SOFA-2 自动化分批处理脚本

# 数据库连接参数
DB_HOST="172.19.160.1"
DB_USER="postgres"
DB_NAME="mimiciv"
DB_PASS="188211"

# 分批参数
BATCH_SIZE=100  # 每批处理的患者数量
OUTPUT_DIR="./sofa2_results"

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

echo "开始SOFA-2分批处理..."
echo "每批处理 $BATCH_SIZE 个患者"
echo "输出目录: $OUTPUT_DIR"

# 获取总患者数和批次数
TOTAL_STAYS=$(PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
    SELECT COUNT(DISTINCT stay_id) FROM mimiciv_derived.icustay_hourly WHERE hr BETWEEN 0 AND 24;
" | tr -d ' ')

BATCH_COUNT=$(( ($TOTAL_STAYS + $BATCH_SIZE - 1) / $BATCH_SIZE ))

echo "总患者数: $TOTAL_STAYS"
echo "总批次数: $BATCH_COUNT"
echo "================================"

# 分批处理循环
for (( i=1; i<=BATCH_COUNT; i++ )); do
    OFFSET=$(( ($i - 1) * $BATCH_SIZE ))

    echo "处理第 $i/$BATCH_COUNT 批 (OFFSET: $OFFSET)..."

    # 创建临时SQL文件
    TEMP_SQL="temp_batch_$i.sql"

    # 生成批次特定的SQL
    sed "s/LIMIT 50 OFFSET 0/LIMIT $BATCH_SIZE OFFSET $OFFSET/g" \
        sofa2_complete_fixed_review.sql > "$TEMP_SQL"

    # 更新批次标识（如果有的话）
    sed "s/'BATCH_1'/'BATCH_$i'/g" "$TEMP_SQL" > "${TEMP_SQL}.updated"
    mv "${TEMP_SQL}.updated" "$TEMP_SQL"

    # 执行查询并保存结果
    OUTPUT_FILE="$OUTPUT_DIR/sofa2_batch_$i.csv"

    PGPASSWORD=$DB_PASS psql -h $DB_HOST -U $DB_USER -d $DB_NAME \
        -f "$TEMP_SQL" \
        --csv \
        -o "$OUTPUT_FILE"

    # 检查执行结果
    if [ $? -eq 0 ]; then
        RECORDS=$(wc -l < "$OUTPUT_FILE")
        echo "✅ 第 $i 批完成，输出 $RECORDS 条记录到 $OUTPUT_FILE"
    else
        echo "❌ 第 $i 批执行失败"
    fi

    # 清理临时文件
    rm -f "$TEMP_SQL"

    # 短暂休息以减轻数据库压力
    sleep 2
done

echo "================================"
echo "所有批次处理完成！"
echo "结果文件保存在: $OUTPUT_DIR/"

# 合并所有批次（可选）
echo "正在合并所有批次结果..."
HEAD_FILE="$OUTPUT_DIR/header.csv"
TAIL_FILES=""

# 获取头部
head -n 1 "$OUTPUT_DIR/sofa2_batch_1.csv" > "$HEAD_FILE"

# 合并所有批次数据
for file in "$OUTPUT_DIR"/sofa2_batch_*.csv; do
    if [ "$TAIL_FILES" = "" ]; then
        TAIL_FILES=$(tail -n +2 "$file")
    else
        TAIL_FILES=$TAIL_FILES$'\n'$(tail -n +2 "$file")
    fi
done

echo -e "$TAIL_FILES" > "$OUTPUT_DIR/combined_results.csv"
cat "$HEAD_FILE" "$OUTPUT_DIR/combined_results.csv" > "$OUTPUT_DIR/sofa2_final.csv"
rm -f "$OUTPUT_DIR/combined_results.csv" "$HEAD_FILE"

echo "✅ 最终合并文件: $OUTPUT_DIR/sofa2_final.csv"