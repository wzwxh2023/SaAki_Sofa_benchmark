#!/usr/bin/env bash

# SOFA2 多阶段控制器 - 可以单独运行每个阶段或连续运行所有阶段
# 用法: ./run_sofa2_stages_controller.sh [stage_number]
# 如果不提供参数，将显示可用阶段

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOG_DIR}"

# 阶段定义
declare -A STAGES=(
    [1]="基础数据预处理: run_sofa2_stage1.sh: 包含镇静、谵妄药物预处理，GCS数据处理"
    [2]="呼吸系统数据预处理: run_sofa2_stage2.sh: PF比值、SF比值、ECMO、呼吸支持数据"
    [3]="循环系统数据预处理: run_sofa2_stage3.sh: 机械支持、生命体征、血管活性药物"
    [4]="其他器官系统数据预处理: run_sofa2_stage4.sh: 胆红素、肾脏、血小板数据"
    [5]="最终评分计算: run_sofa2_stage5.sh: 整合所有数据，计算SOFA2评分"
    [6]="索引创建和清理: run_sofa2_stage6.sh: 创建索引，清理临时表"
)

# 显示帮助信息
show_help() {
    echo "🎯 SOFA2 多阶段执行控制器"
    echo ""
    echo "📋 可用阶段："
    for i in {1..6}; do
        IFS=':' read -r script_name description <<< "${STAGES[$i]}"
        echo "  阶段 $i: $script_name"
        echo "       $description"
        echo ""
    done
    echo "💡 用法："
    echo "  $0 [阶段编号]              # 运行指定阶段"
    echo "  $0 --all                   # 运行所有阶段（顺序执行）"
    echo "  $0 --list                  # 显示所有阶段"
    echo "  $0 --help                  # 显示此帮助信息"
}

# 运行指定阶段
run_stage() {
    local stage_num=$1
    local stage_info="${STAGES[$stage_num]}"

    if [[ -z "$stage_info" ]]; then
        echo "❌ 错误：无效的阶段编号 $stage_num"
        show_help
        exit 1
    fi

    IFS=':' read -r stage_name script_name description <<< "$stage_info"

    echo "🚀 开始执行阶段 $stage_num: $stage_name"
    echo "📝 描述: $description"
    echo "⏱️ 开始时间: $(date)"

    local script_path="${SCRIPT_DIR}/${script_name}"
    if [[ ! -f "$script_path" ]]; then
        echo "❌ 错误：脚本文件不存在 $script_path"
        exit 1
    fi

    # 设置阶段专用的日志文件
    local stage_log="${LOG_DIR}/sofa2_stage${stage_num}_$(date +'%Y%m%d_%H%M%S').log"

    # 执行阶段脚本
    if "$script_path" 2>&1 | tee "$stage_log"; then
        echo "✅ 阶段 $stage_num 完成: $stage_name"
        echo "📊 完成时间: $(date)"
        echo "📋 日志文件: $stage_log"
        return 0
    else
        echo "❌ 阶段 $stage_num 失败: $stage_name"
        echo "📋 错误日志: $stage_log"
        return 1
    fi
}

# 运行所有阶段
run_all_stages() {
    echo "🎯 开始执行所有SOFA2阶段"
    echo "⏱️ 总开始时间: $(date)"

    local total_start=$(date +%s)
    local failed_stages=()

    for stage_num in {1..6}; do
        echo ""
        echo "================================================================================"
        echo "阶段 $stage_num/6"
        echo "================================================================================"

        if run_stage "$stage_num"; then
            echo "✅ 阶段 $stage_num 成功完成"
        else
            echo "❌ 阶段 $stage_num 执行失败"
            failed_stages+=($stage_num)

            # 询问是否继续
            echo ""
            read -p "❓ 继续执行下一个阶段吗？(y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "🛑 用户选择停止执行"
                break
            fi
        fi

        # 阶段间暂停，让数据库稳定
        echo "⏳ 等待5秒后继续下一个阶段..."
        sleep 5
    done

    local total_end=$(date +%s)
    local total_duration=$((total_end - total_start))

    echo ""
    echo "================================================================================"
    echo "🏁 所有阶段执行完成"
    echo "================================================================================"
    echo "⏱️ 总耗时: $((total_duration / 3600))小时 $(((total_duration % 3600) / 60))分钟"
    echo "📊 完成时间: $(date)"

    if [[ ${#failed_stages[@]} -eq 0 ]]; then
        echo "🎉 所有阶段都成功完成！"
    else
        echo "⚠️ 失败的阶段: ${failed_stages[*]}"
        echo "💡 请检查相应的日志文件进行故障排除"
    fi
}

# 主逻辑
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            ;;
        --list)
            show_help
            ;;
        --all)
            run_all_stages
            ;;
        [1-6])
            run_stage "$1"
            ;;
        "")
            show_help
            ;;
        *)
            echo "❌ 错误：无效的参数 '$1'"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"