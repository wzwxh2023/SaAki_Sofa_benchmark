#!/bin/bash
# =================================================================
# SOFA2 完整运行脚本（使用基于ICU入院时间的hourly表）
# =================================================================

# 数据库连接参数
export PGPASSWORD=188211
DB_HOST="172.19.160.1"
DB_USER="postgres"
DB_NAME="mimiciv_31"

# 日志文件
LOG_DIR="/mnt/f/SaAki_Sofa_benchmark/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/sofa2_complete_${TIMESTAMP}.log"

# 创建日志目录
mkdir -p $LOG_DIR

echo "=========================================" | tee -a $LOG_FILE
echo "SOFA2 完整计算流程 - 开始运行" | tee -a $LOG_FILE
echo "时间: $(date)" | tee -a $LOG_FILE
echo "=========================================" | tee -a $LOG_FILE

# SQL脚本目录
SQL_DIR="/mnt/f/SaAki_Sofa_benchmark/sofa2_sql"

# 运行步骤1：环境配置与清理
echo -e "\n[步骤 1/8] 环境配置与清理..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/01_setup_cleanup.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤1完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 运行步骤2：创建各组件表
echo -e "\n[步骤 2/8] 创建各组件表..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/02_stage_components.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤2完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 运行步骤3：计算每小时原始评分
echo -e "\n[步骤 3/8] 计算每小时原始评分..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/03_hourly_raw_scores.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤3完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 运行步骤4：计算24小时滑动窗口最差分
echo -e "\n[步骤 4/8] 计算24小时滑动窗口最差分..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/04_window_final_scores.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤4完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 运行步骤5：过滤hr>=0
echo -e "\n[步骤 5/8] 过滤hr>=0..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/05_filter_hr_nonnegative.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤5完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 运行步骤6：创建first_day_sofa2表
echo -e "\n[步骤 6/8] 创建first_day_sofa2表..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/06_first_day_sofa2_simple.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤6完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 运行步骤7：创建sepsis3_sofa2表
echo -e "\n[步骤 7/8] 创建sepsis3_sofa2表..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/07_sepsis3_sofa2_delta.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤7完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 运行步骤8：提取结局数据
echo -e "\n[步骤 8/8] 提取结局数据..." | tee -a $LOG_FILE
start_time=$(date +%s)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f "${SQL_DIR}/08_extract_outcomes_final_corrected.sql" 2>&1 | tee -a $LOG_FILE
end_time=$(date +%s)
echo "步骤8完成，耗时: $((($end_time - $start_time) / 60)) 分钟" | tee -a $LOG_FILE

# 验证结果
echo -e "\n=========================================" | tee -a $LOG_FILE
echo "验证SOFA2计算结果..." | tee -a $LOG_FILE
echo "=========================================" | tee -a $LOG_FILE

# 检查患者30217312的SOFA2评分
echo -e "\n患者 30217312 的SOFA2评分：" | tee -a $LOG_FILE
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT
    'SOFA2' as score_type,
    sofa2_total,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis
FROM mimiciv_derived.first_day_sofa2
WHERE stay_id = 30217312;" 2>&1 | tee -a $LOG_FILE

# 对比SOFA评分
echo -e "\n患者 30217312 的SOFA评分（原始）：" | tee -a $LOG_FILE
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT
    'SOFA (Original)' as score_type,
    sofa as sofa_total,
    cns as brain,
    respiration as respiratory,
    cardiovascular,
    liver,
    renal as kidney,
    coagulation as hemostasis
FROM mimiciv_derived.first_day_sofa
WHERE stay_id = 30217312;" 2>&1 | tee -a $LOG_FILE

# 统计信息
echo -e "\n=========================================" | tee -a $LOG_FILE
echo "统计信息：" | tee -a $LOG_FILE
echo "=========================================" | tee -a $LOG_FILE

psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT
    'first_day_sofa2' as table_name,
    COUNT(*) as total_patients,
    ROUND(AVG(sofa2_total), 2) as avg_sofa2,
    MAX(sofa2_total) as max_sofa2,
    ROUND(100.0 * COUNT(*) FILTER (WHERE sofa2_total >= 2) / COUNT(*), 2) as pct_sofa2_ge_2
FROM mimiciv_derived.first_day_sofa2;" 2>&1 | tee -a $LOG_FILE

echo -e "\n=========================================" | tee -a $LOG_FILE
echo "SOFA2 计算完成！" | tee -a $LOG_FILE
echo "结束时间: $(date)" | tee -a $LOG_FILE
echo "日志文件: $LOG_FILE" | tee -a $LOG_FILE
echo "=========================================" | tee -a $LOG_FILE