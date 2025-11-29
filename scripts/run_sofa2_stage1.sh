#!/usr/bin/env bash

# SOFA2 阶段1: 基础数据预处理
# 包含：镇静、谵妄药物预处理，GCS数据处理

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SQL_FILE="${REPO_ROOT}/sofa2_sql/sofa2_stage1_basic_preprocessing.sql"

if [[ ! -f "${SQL_FILE}" ]]; then
    echo "未找到 SQL 文件：${SQL_FILE}" >&2
    exit 1
fi

LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sofa2_stage1_$(date +'%Y%m%d_%H%M%S').log"

# 数据库连接配置
: "${PGHOST:=172.19.160.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=mimiciv}"
: "${PGPASSWORD:=188211}"

export PGPASSWORD

echo "🚀 SOFA2 阶段1开始：基础数据预处理"
echo "📝 日志文件：${LOG_FILE}"
echo "⏱️ 开始时间：$(date)"
echo "🎯 包含：镇静药物、谵妄药物、GCS数据处理" | tee -a "${LOG_FILE}"

{
    echo "\\echo '验证数据库连接...';"
    echo "SELECT version();"
    echo "\set ON_ERROR_STOP on"
    echo "\timing on"
    echo "SET work_mem = '256MB';"
    echo "SET maintenance_work_mem = '512MB';"
    echo "SET max_parallel_workers_per_gather = 4;"
    echo "SET temp_buffers = '64MB';"
    echo "SET statement_timeout = '7200s';"
    echo "SET client_min_messages = 'INFO';"
    echo "\\echo '🔄 开始执行阶段1：基础数据预处理...';"
    echo "\\i '${SQL_FILE}';"
    echo "\\echo '✅ 阶段1完成！';"
} | psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
    | tee -a "${LOG_FILE}"

echo "🏁 SOFA2 阶段1完成：$(date)" | tee -a "${LOG_FILE}"
echo "📊 完成时间：$(date)" | tee -a "${LOG_FILE}"
echo "📋 日志文件：${LOG_FILE}"