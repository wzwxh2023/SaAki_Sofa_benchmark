#!/usr/bin/env bash

# 分批运行 SOFA2 评分计算，避免单次超长运行
# 默认按 stay_id 升序分块，可通过环境变量覆盖连接信息或块大小

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SQL_FILE="${REPO_ROOT}/sofa2_sql/sofa2_optimized_chunk.sql"

if [[ ! -f "${SQL_FILE}" ]]; then
    echo "未找到 SQL 文件：${SQL_FILE}" >&2
    exit 1
fi

: "${PGHOST:=172.19.160.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=mimiciv}"
: "${PGPASSWORD:=188211}"
: "${CHUNK_SIZE:=2000}"

export PGPASSWORD

LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sofa2_chunked_$(date +'%Y%m%d_%H%M%S').log"

echo "SOFA2 分批任务启动：$(date)" | tee -a "${LOG_FILE}"
echo "块大小：${CHUNK_SIZE} stay_id" | tee -a "${LOG_FILE}"

STAY_RANGE=$(psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -t -A \
    -c "SELECT COALESCE(MIN(stay_id),0)::text || '|' || COALESCE(MAX(stay_id),0)::text FROM mimiciv_icu.icustays;"
)
STAY_RANGE="${STAY_RANGE//[$'\r\n']}"

if [[ -z "${STAY_RANGE}" || "${STAY_RANGE}" != *"|"* ]]; then
    echo "无法获取 stay_id 范围，请检查数据库连接" | tee -a "${LOG_FILE}"
    exit 1
fi

IFS='|' read -r STAY_MIN STAY_MAX <<< "${STAY_RANGE}"

echo "stay_id 范围：${STAY_MIN} - ${STAY_MAX}" | tee -a "${LOG_FILE}"

chunk_start="${STAY_MIN}"
while [[ "${chunk_start}" -le "${STAY_MAX}" ]]; do
    chunk_end=$(( chunk_start + CHUNK_SIZE - 1 ))
    if [[ "${chunk_end}" -gt "${STAY_MAX}" ]]; then
        chunk_end="${STAY_MAX}"
    fi

    echo ">>> 处理块 [${chunk_start}, ${chunk_end}]" | tee -a "${LOG_FILE}"
    {
        echo "\set ON_ERROR_STOP on"
        echo "\timing on"
        echo "SET work_mem = '1GB';"
        echo "SET maintenance_work_mem = '1GB';"
        echo "SET max_parallel_workers_per_gather = 8;"
        echo "SET statement_timeout = 0;"
        echo "SET lock_timeout = 0;"
        echo "\set chunk_min ${chunk_start}"
        echo "\set chunk_max ${chunk_end}"
        echo "\\i '${SQL_FILE}'"
    } | psql -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
        | tee -a "${LOG_FILE}"

    echo "<<< 完成块 [${chunk_start}, ${chunk_end}]" | tee -a "${LOG_FILE}"
    chunk_start=$(( chunk_end + 1 ))
done

echo "SOFA2 分批任务结束：$(date)" | tee -a "${LOG_FILE}"
