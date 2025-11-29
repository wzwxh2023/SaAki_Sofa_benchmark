#!/usr/bin/env bash

# =================================================================
# SOFA2评分系统优化分块执行脚本 V2
# 避免覆盖现有表，充分利用系统资源，最快速度执行
# =================================================================

set -euo pipefail
IFS=$'\n\t'

# 数据库连接配置
: "${PGHOST:=172.19.160.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=mimiciv}"
: "${PGPASSWORD:=188211}"

export PGPASSWORD
export PGHOST PGPORT PGUSER PGDATABASE

# 日期和时间戳用于日志
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="sofa2_run_v2_${TIMESTAMP}.log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    case $level in
        "INFO")  color=$GREEN ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "DEBUG") color=$BLUE ;;
        *)       color=$NC ;;
    esac

    echo -e "${color}[$timestamp] [$level] $message${NC}" | tee -a "$LOG_FILE"
}

# 执行SQL命令并记录执行时间
execute_sql() {
    local sql="$1"
    local description="$2"
    local timeout_duration="${3:-3600}"  # 默认1小时超时

    log "INFO" "开始执行: $description"
    local start_time=$(date +%s)

    # 使用timeout防止长时间卡死
    if timeout "$timeout_duration" bash -c "psql -X -a -v ON_ERROR_STOP=1 <<'EOF'
$sql
EOF" 2>&1 | tee -a "$LOG_FILE"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local minutes=$((duration / 60))
        local seconds=$((duration % 60))
        log "INFO" "完成: $description (耗时: ${minutes}分${seconds}秒)"
        return 0
    else
        local exit_code=$?
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local minutes=$((duration / 60))
        local seconds=$((duration % 60))
        log "ERROR" "失败: $description (耗时: ${minutes}分${seconds}秒, 退出码: $exit_code)"
        return $exit_code
    fi
}

# 检查数据库连接
check_connection() {
    log "INFO" "检查数据库连接..."
    if ! psql -c "SELECT 1;" >/dev/null 2>&1; then
        log "ERROR" "无法连接到数据库"
        exit 1
    fi
    log "INFO" "数据库连接正常"
}

# 检查表是否存在
check_table_exists() {
    local table_name="$1"
    if psql -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '$table_name');" | grep -q "t"; then
        return 0
    else
        return 1
    fi
}

# 获取表记录数
get_table_count() {
    local table_name="$1"
    psql -t -c "SELECT COUNT(*) FROM $table_name;" | tr -d ' '
}

# 获取系统资源状态
get_system_status() {
    log "INFO" "系统资源状态:"

    # CPU使用率
    if command -v mpstat >/dev/null 2>&1; then
        cpu_usage=$(mpstat 1 1 | awk '/Average:/ {print 100 - $NF}' | tail -1)
        log "INFO" "CPU使用率: ${cpu_usage}%"
    fi

    # 内存使用率
    if command -v free >/dev/null 2>&1; then
        mem_info=$(free | grep '^Mem:')
        total_mem=$(echo $mem_info | awk '{print $2}')
        used_mem=$(echo $mem_info | awk '{print $3}')
        mem_usage=$((used_mem * 100 / total_mem))
        log "INFO" "内存使用率: ${mem_usage}%"
    fi

    # 磁盘空间
    if command -v df >/dev/null 2>&1; then
        disk_usage=$(df -h . | awk 'NR==2 {print $5}')
        log "INFO" "磁盘使用率: $disk_usage"
    fi

    # 数据库连接数
    local db_connections=$(psql -t -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';" | tr -d ' ')
    log "INFO" "活跃数据库连接: $db_connections"
}

# 优化PostgreSQL配置
optimize_postgresql() {
    log "INFO" "优化PostgreSQL会话配置..."

    execute_sql "
        -- 性能优化配置
        SET work_mem = '512MB';
        SET maintenance_work_mem = '1GB';
        SET effective_cache_size = '8GB';
        SET random_page_cost = 1.1;
        SET max_parallel_workers_per_gather = 8;
        SET parallel_tuple_cost = 100;
        SET parallel_setup_cost = 1000;
        SET enable_partitionwise_join = on;
        SET enable_partitionwise_aggregate = on;
        SET jit = off;
        SET statement_timeout = '7200s';  -- 2小时超时
        SET lock_timeout = '3600s';       -- 1小时锁超时

        -- 验证配置
        SHOW work_mem;
        SHOW max_parallel_workers_per_gather;
    " "PostgreSQL性能优化"
}

# 创建进度监控表
create_progress_table() {
    log "INFO" "创建进度监控表..."

    execute_sql "
        -- 创建进度监控表
        CREATE TABLE IF NOT EXISTS sofa2_run_progress_v2 (
            run_id SERIAL PRIMARY KEY,
            start_time TIMESTAMP DEFAULT NOW(),
            stage VARCHAR(100),
            status VARCHAR(20),
            details TEXT,
            duration INTERVAL
        );

        -- 清理旧的进度记录
        DELETE FROM sofa2_run_progress_v2 WHERE start_time < NOW() - INTERVAL '1 day';

        -- 插入开始记录
        INSERT INTO sofa2_run_progress_v2 (stage, status, details)
        VALUES ('SOFA2 V2 开始', 'STARTING', '第二次运行，使用新表名 sofa2_scores_v2');

        SELECT '进度监控表准备完成' AS status;
    " "创建进度监控表"
}

# 主执行函数
main() {
    log "INFO" "==============================================="
    log "INFO" "SOFA2评分系统优化分块执行 V2"
    log "INFO" "目标: 不覆盖现有表，最快速度执行"
    log "INFO" "==============================================="

    # 检查数据库连接
    check_connection

    # 检查现有表
    if check_table_exists "mimiciv_derived.sofa2_scores"; then
        local existing_count=$(get_table_count "mimiciv_derived.sofa2_scores")
        log "INFO" "现有sofa2_scores表包含 $existing_count 条记录"
    fi

    # 检查目标表是否已存在
    if check_table_exists "mimiciv_derived.sofa2_scores_v2"; then
        local v2_count=$(get_table_count "mimiciv_derived.sofa2_scores_v2")
        log "WARN" "目标表sofa2_scores_v2已存在，包含 $v2_count 条记录"
        read -p "是否删除并重建？(y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            execute_sql "DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores_v2 CASCADE;" "删除现有V2表"
        else
            log "INFO" "退出脚本"
            exit 0
        fi
    fi

    # 获取系统状态
    get_system_status

    # 优化PostgreSQL配置
    optimize_postgresql

    # 创建进度监控表
    create_progress_table

    log "INFO" "开始执行SOFA2评分计算..."

    # 执行优化后的SOFA2脚本
    local script_path="../sofa2_sql/sofa2_optimized_v2.sql"
    if [[ ! -f "$script_path" ]]; then
        log "ERROR" "SQL脚本文件不存在: $script_path"
        exit 1
    fi

    # 执行SQL脚本，设置4小时超时
    local start_time=$(date +%s)

    if timeout 14400 bash -c "psql -X -a -v ON_ERROR_STOP=1 < '$script_path'" 2>&1 | tee -a "$LOG_FILE"; then
        local end_time=$(date +%s)
        local total_duration=$((end_time - start_time))
        local hours=$((total_duration / 3600))
        local minutes=$(((total_duration % 3600) / 60))
        local seconds=$((total_duration % 60))

        log "INFO" "==============================================="
        log "INFO" "SOFA2评分计算完成！"
        log "INFO" "总耗时: ${hours}小时${minutes}分${seconds}秒"
        log "INFO" "==============================================="

        # 检查结果
        if check_table_exists "mimiciv_derived.sofa2_scores_v2"; then
            local final_count=$(get_table_count "mimiciv_derived.sofa2_scores_v2")
            log "INFO" "新表sofa2_scores_v2包含 $final_count 条记录"

            # 显示统计信息
            execute_sql "
                SELECT
                    '最终统计' AS category,
                    COUNT(*) AS total_records,
                    COUNT(DISTINCT stay_id) AS unique_stays,
                    COUNT(DISTINCT subject_id) AS unique_patients,
                    ROUND(AVG(sofa2_total), 2) AS avg_score,
                    MIN(sofa2_total) AS min_score,
                    MAX(sofa2_total) AS max_score
                FROM mimiciv_derived.sofa2_scores_v2;
            " "最终统计信息"
        fi

    else
        log "ERROR" "SOFA2评分计算失败或超时"
        log "ERROR" "请查看日志文件: $LOG_FILE"
        exit 1
    fi

    log "INFO" "执行完成，日志文件: $LOG_FILE"
}

# 错误处理
trap 'log "ERROR" "脚本被中断"; exit 1' INT TERM

# 运行主函数
main "$@"