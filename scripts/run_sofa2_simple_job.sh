#!/usr/bin/env bash

# SOFA2 简化配置脚本 - 回到之前成功的参数配置

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SQL_FILE="${REPO_ROOT}/sofa2_sql/sofa2_optimized.sql"

if [[ ! -f "${SQL_FILE}" ]]; then
    echo "未找到 SQL 文件：${SQL_FILE}" >&2
    exit 1
fi

LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sofa2_simple_job_$(date +'%Y%m%d_%H%M%S').log"

# 使用更保守的配置参数
: "${PGHOST:=172.19.160.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=mimiciv}"
: "${PGPASSWORD:=188211}"

export PGPASSWORD

echo "🔄 SOFA2 简化配置批处理开始：$(date)" | tee -a "${LOG_FILE}"
echo "📝 日志文件：${LOG_FILE}"
echo "⚠️ 使用保守配置，基于之前19小时成功的经验" | tee -a "${LOG_FILE}"

{
    echo "\\echo '验证数据库连接...';"
    echo "SELECT version();"
    echo "\set ON_ERROR_STOP on"
    echo "\timing on"
    # 保守的配置参数
    echo "SET work_mem = '256MB';"
    echo "SET maintenance_work_mem = '512MB';"
    echo "SET max_parallel_workers_per_gather = 4;"
    echo "SET temp_buffers = '64MB';"
    echo "SET statement_timeout = '7200s';"
    echo "SET lock_timeout = '300s';"
    echo "SET client_min_messages = 'INFO';"
    echo "\\echo '使用保守配置启动 SOFA2 脚本...';"
    echo "\\i '${SQL_FILE}';"
    echo "\\echo '🎉 SOFA2 批处理完成。';"
} | psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
    | tee -a "${LOG_FILE}"

echo "🔄 SOFA2 简化配置批处理结束：$(date)" | tee -a "${LOG_FILE}"