#!/usr/bin/env bash

# SOFA2 安全执行脚本 - 保护原有 sofa2_scores 表
# 使用 sofa2_minimal_success.sql 创建 sofa2_scores_v3 表

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 使用安全版本的SQL文件（创建sofa2_scores_v3，不覆盖原表）
SQL_FILE="${REPO_ROOT}/sofa2_sql/sofa2_minimal_success.sql"

if [[ ! -f "${SQL_FILE}" ]]; then
    echo "未找到 SQL 文件：${SQL_FILE}" >&2
    exit 1
fi

LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sofa2_safe_job_$(date +'%Y%m%d_%H%M%S').log"

# 允许外部覆盖连接配置，否则使用默认值
: "${PGHOST:=172.19.160.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=mimiciv}"
: "${PGPASSWORD:=188211}"

export PGPASSWORD

echo "🛡️  SOFA2 安全批处理开始：$(date)" | tee -a "${LOG_FILE}"
echo "📝 日志文件：${LOG_FILE}"
echo "🔒 使用安全版本，将创建 sofa2_scores_v3 表（不覆盖原有 sofa2_scores）" | tee -a "${LOG_FILE}"

# 首先检查原有的sofa2_scores表是否存在
echo "🔍 检查原有的 sofa2_scores 表..." | tee -a "${LOG_FILE}"
if psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -c "\dt mimiciv_derived.sofa2_scores" | grep -q "sofa2_scores"; then
    echo "✅ 检测到原有的 sofa2_scores 表，将受到保护" | tee -a "${LOG_FILE}"
else
    echo "ℹ️  未检测到原有的 sofa2_scores 表" | tee -a "${LOG_FILE}"
fi

{
    echo "\\echo '验证数据库连接...';"
    echo "SELECT version();"
    echo "\set ON_ERROR_STOP on"
    echo "\timing on"
    echo "SET work_mem = '256MB';"        # 使用保守的内存设置
    echo "SET maintenance_work_mem = '512MB';"
    echo "SET max_parallel_workers_per_gather = 4;"  # 保守的并行设置
    echo "SET temp_buffers = '128MB';"
    echo "SET statement_timeout = '3600s';"  # 1小时超时
    echo "SET lock_timeout = '300s';"       # 5分钟锁超时
    echo "SET client_min_messages = 'INFO';"
    echo "\\echo '🚀 启动 SOFA2 安全脚本...';"
    echo "\\i '${SQL_FILE}';"
    echo "\\echo '🎉 SOFA2 安全批处理完成。';"
    echo "\\echo '✅ 新表已创建：mimiciv_derived.sofa2_scores_v3'"
    echo "\\echo '🔒 原有表 mimiciv_derived.sofa2_scores 保持不变'"
} | psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
    | tee -a "${LOG_FILE}"

echo "🛡️  SOFA2 安全批处理结束：$(date)" | tee -a "${LOG_FILE}"
echo "📋 总结：" | tee -a "${LOG_FILE}"
echo "   - 原有 sofa2_scores 表：未动" | tee -a "${LOG_FILE}"
echo "   - 新建 sofa2_scores_v3 表：已完成" | tee -a "${LOG_FILE}"