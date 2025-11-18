#!/usr/bin/env bash

# 离线批量生成 SOFA2 评分表的便捷脚本：
# 1. 仅在当前会话设置高性能参数，无需修改 postgresql.conf
# 2. 可通过 nohup 挂后台执行，输出日志位于 logs/ 目录

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
LOG_FILE="${LOG_DIR}/sofa2_job_$(date +'%Y%m%d_%H%M%S').log"

# 允许外部覆盖连接配置，否则使用默认值
: "${PGHOST:=172.19.160.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=mimiciv}"
: "${PGPASSWORD:=188211}"

export PGPASSWORD

echo "SOFA2 批处理开始：$(date)" | tee -a "${LOG_FILE}"
echo "日志文件：${LOG_FILE}"

{
    echo "\\echo '验证数据库连接...';"
    echo "SELECT version();"
    echo "\set ON_ERROR_STOP on"
    echo "\timing on"
    echo "SET work_mem = '1GB';"
    echo "SET maintenance_work_mem = '1GB';"
    echo "SET max_parallel_workers_per_gather = 8;"
    echo "SET max_parallel_workers = 16;"
    echo "SET temp_buffers = '512MB';"
    echo "SET statement_timeout = 0;"
    echo "SET lock_timeout = 0;"
    echo "SET client_min_messages = 'INFO';"
    echo "\\echo '刷新关键表统计信息...';"
    echo "ANALYZE mimiciv_icu.icustays;"
    echo "ANALYZE mimiciv_derived.vasoactive_agent;"
    echo "ANALYZE mimiciv_derived.urine_output;"
    echo "ANALYZE mimiciv_derived.bg;"
    echo "ANALYZE mimiciv_derived.enzyme;"
    echo "ANALYZE mimiciv_derived.complete_blood_count;"
    echo "ANALYZE mimiciv_derived.gcs;"
    echo "\\echo '启动 SOFA2 优化脚本...';"
    echo "\\i '${SQL_FILE}';"
    echo "\\echo 'SOFA2 批处理完成。';"
} | psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
    | tee -a "${LOG_FILE}"

echo "SOFA2 批处理结束：$(date)" | tee -a "${LOG_FILE}"
