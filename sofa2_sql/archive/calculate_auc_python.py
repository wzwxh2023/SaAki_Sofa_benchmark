#!/usr/bin/env python3
"""
SOFA vs SOFA2 ICU生存预测AUC计算脚本
使用方法：
1. 先运行 generate_auc_data_csv.sql 获取CSV数据
2. 将CSV数据保存为 survival_auc_data.csv
3. 运行此脚本：python calculate_auc_python.py
"""

import pandas as pd
import numpy as np
from sklearn.metrics import roc_auc_score, roc_curve, precision_recall_curve, auc
from sklearn.model_selection import StratifiedKFold, cross_val_score
import matplotlib.pyplot as plt
import seaborn as sns
from scipy import stats
import warnings
warnings.filterwarnings('ignore')

def load_and_prepare_data(csv_file='survival_auc_data.csv'):
    """加载并准备数据"""
    print("📊 加载数据...")

    # 读取CSV数据
    df = pd.read_csv(csv_file)

    print(f"✅ 数据加载完成：{len(df)} 行, {len(df.columns)} 列")
    print(f"📋 列名：{list(df.columns)}")

    # 数据清洗
    df['icu_mortality'] = df['icu_mortality'].astype(int)
    df['hospital_expire_flag'] = df['hospital_expire_flag'].astype(int)
    df['sofa_score'] = df['sofa_score'].astype(float)
    df['sofa2_score'] = df['sofa2_score'].astype(float)

    # 检查数据完整性
    missing_data = df.isnull().sum()
    if missing_data.sum() > 0:
        print(f"⚠️  发现缺失数据：\n{missing_data[missing_data > 0]}")

    return df

def calculate_basic_statistics(df):
    """计算基础统计信息"""
    print("\n📈 基础统计分析")
    print("=" * 50)

    # 总体统计
    total_patients = len(df)
    icu_deaths = df['icu_mortality'].sum()
    hospital_deaths = df['hospital_expire_flag'].sum()

    print(f"总患者数：{total_patients:,}")
    print(f"ICU死亡数：{icu_deaths:,} ({icu_deaths/total_patients*100:.2f}%)")
    print(f"医院死亡数：{hospital_deaths:,} ({hospital_deaths/total_patients*100:.2f}%)")

    # 评分统计
    print(f"\n📊 SOFA评分统计：")
    print(f"SOFA-1 平均分：{df['sofa_score'].mean():.2f} ± {df['sofa_score'].std():.2f}")
    print(f"SOFA-1 中位数：{df['sofa_score'].median():.2f}")
    print(f"SOFA-1 范围：{df['sofa_score'].min()}-{df['sofa_score'].max()}")

    print(f"\n📊 SOFA-2评分统计：")
    print(f"SOFA-2 平均分：{df['sofa2_score'].mean():.2f} ± {df['sofa2_score'].std():.2f}")
    print(f"SOFA-2 中位数：{df['sofa2_score'].median():.2f}")
    print(f"SOFA-2 范围：{df['sofa2_score'].min()}-{df['sofa2_score'].max()}")

    # 重症患者分析 (SOFA≥8)
    sofa_severe = df['sofa_score'] >= 8
    sofa2_severe = df['sofa2_score'] >= 8

    print(f"\n🏥 重症患者分析 (SOFA≥8)：")
    print(f"SOFA-1 重症患者：{sofa_severe.sum():,} ({sofa_severe.mean()*100:.2f}%)")
    print(f"SOFA-1 重症死亡率：{df[sofa_severe]['icu_mortality'].mean()*100:.2f}%")

    print(f"SOFA-2 重症患者：{sofa2_severe.sum():,} ({sofa2_severe.mean()*100:.2f}%)")
    print(f"SOFA-2 重症死亡率：{df[sofa2_severe]['icu_mortality'].mean()*100:.2f}%")

def calculate_auc_scores(df):
    """计算AUC分数"""
    print("\n🎯 AUC计算结果")
    print("=" * 50)

    # ICU死亡率预测AUC
    auc_sofa_icu = roc_auc_score(df['icu_mortality'], df['sofa_score'])
    auc_sofa2_icu = roc_auc_score(df['icu_mortality'], df['sofa2_score'])

    # 医院死亡率预测AUC
    auc_sofa_hosp = roc_auc_score(df['hospital_expire_flag'], df['sofa_score'])
    auc_sofa2_hosp = roc_auc_score(df['hospital_expire_flag'], df['sofa2_score'])

    print("🏆 ICU死亡率预测AUC：")
    print(f"SOFA-1: {auc_sofa_icu:.4f}")
    print(f"SOFA-2: {auc_sofa2_icu:.4f}")
    print(f"提升: +{(auc_sofa2_icu - auc_sofa_icu):.4f}")

    print("\n🏆 医院死亡率预测AUC：")
    print(f"SOFA-1: {auc_sofa_hosp:.4f}")
    print(f"SOFA-2: {auc_sofa2_hosp:.4f}")
    print(f"提升: +{(auc_sofa2_hosp - auc_sofa_hosp):.4f}")

    return {
        'sofa_icu_auc': auc_sofa_icu,
        'sofa2_icu_auc': auc_sofa2_icu,
        'sofa_hosp_auc': auc_sofa_hosp,
        'sofa2_hosp_auc': auc_sofa2_hosp
    }

def perform_statistical_test(df, auc_results):
    """执行AUC差异的统计检验"""
    print("\n🔬 AUC差异统计检验")
    print("=" * 50)

    # 使用Delong检验比较AUC差异 (需要额外的库)
    # 这里我们使用bootstrap方法进行简化检验

    def bootstrap_auc(df, score_col, outcome_col, n_bootstrap=1000):
        """Bootstrap方法计算AUC置信区间"""
        np.random.seed(42)
        aucs = []

        for _ in range(n_bootstrap):
            bootstrap_sample = df.sample(n=len(df), replace=True)
            if len(bootstrap_sample[outcome_col].unique()) > 1:  # 确保有正负样本
                auc = roc_auc_score(bootstrap_sample[outcome_col], bootstrap_sample[score_col])
                aucs.append(auc)

        if len(aucs) > 0:
            return np.array(aucs)
        return None

    # ICU死亡率AUC bootstrap
    sofa_aucs = bootstrap_auc(df, 'sofa_score', 'icu_mortality')
    sofa2_aucs = bootstrap_auc(df, 'sofa2_score', 'icu_mortality')

    if sofa_aucs is not None and sofa2_aucs is not None:
        # 计算置信区间
        sofa_ci = np.percentile(sofa_aucs, [2.5, 97.5])
        sofa2_ci = np.percentile(sofa2_aucs, [2.5, 97.5])

        print("ICU死亡率AUC 95%置信区间：")
        print(f"SOFA-1: [{sofa_ci[0]:.4f}, {sofa_ci[1]:.4f}]")
        print(f"SOFA-2: [{sofa2_ci[0]:.4f}, {sofa2_ci[1]:.4f}]")

        # 差异检验
        diff_dist = sofa2_aucs - sofa_aucs
        diff_ci = np.percentile(diff_dist, [2.5, 97.5])
        print(f"SOFA-2 vs SOFA-1 差异: [{diff_ci[0]:.4f}, {diff_ci[1]:.4f}]")

        if diff_ci[0] > 0:
            print("✅ SOFA-2显著优于SOFA-1 (p<0.05)")
        elif diff_ci[1] < 0:
            print("❌ SOFA-2显著劣于SOFA-1 (p<0.05)")
        else:
            print("➖️ 两种评分系统无显著差异")

def plot_roc_curves(df, auc_results):
    """绘制ROC曲线"""
    print("\n📊 生成ROC曲线...")

    fig, axes = plt.subplots(1, 2, figsize=(15, 6))

    # ICU死亡率ROC曲线
    fpr_sofa, tpr_sofa, _ = roc_curve(df['icu_mortality'], df['sofa_score'])
    fpr_sofa2, tpr_sofa2, _ = roc_curve(df['icu_mortality'], df['sofa2_score'])

    axes[0].plot(fpr_sofa, tpr_sofa, label=f'SOFA-1 (AUC={auc_results["sofa_icu_auc"]:.3f})',
                 color='blue', linewidth=2)
    axes[0].plot(fpr_sofa2, tpr_sofa2, label=f'SOFA-2 (AUC={auc_results["sofa2_icu_auc"]:.3f})',
                 color='red', linewidth=2, linestyle='--')
    axes[0].plot([0, 1], [0, 1], 'k--', linewidth=1)
    axes[0].set_xlabel('False Positive Rate')
    axes[0].set_ylabel('True Positive Rate')
    axes[0].set_title('ICU死亡率预测ROC曲线')
    axes[0].legend()
    axes[0].grid(True, alpha=0.3)

    # 医院死亡率ROC曲线
    fpr_sofa_h, tpr_sofa_h, _ = roc_curve(df['hospital_expire_flag'], df['sofa_score'])
    fpr_sofa2_h, tpr_sofa2_h, _ = roc_curve(df['hospital_expire_flag'], df['sofa2_score'])

    axes[1].plot(fpr_sofa_h, tpr_sofa_h, label=f'SOFA-1 (AUC={auc_results["sofa_hosp_auc"]:.3f})',
                 color='blue', linewidth=2)
    axes[1].plot(fpr_sofa2_h, tpr_sofa2_h, label=f'SOFA-2 (AUC={auc_results["sofa2_hosp_auc"]:.3f})',
                 color='red', linewidth=2, linestyle='--')
    axes[1].plot([0, 1], [0, 1], 'k--', linewidth=1)
    axes[1].set_xlabel('False Positive Rate')
    axes[1].set_ylabel('True Positive Rate')
    axes[1].set_title('医院死亡率预测ROC曲线')
    axes[1].legend()
    axes[1].grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig('sofa_vs_sofa2_roc_curves.png', dpi=300, bbox_inches='tight')
    print("💾 ROC曲线已保存为 'sofa_vs_sofa2_roc_curves.png'")

def analyze_score_distributions(df):
    """分析评分分布"""
    print("\n📊 评分分布分析")
    print("=" * 50)

    fig, axes = plt.subplots(2, 2, figsize=(15, 12))

    # SOFA评分分布
    axes[0, 0].hist(df['sofa_score'], bins=25, alpha=0.7, color='blue', edgecolor='black')
    axes[0, 0].set_xlabel('SOFA-1评分')
    axes[0, 0].set_ylabel('患者数量')
    axes[0, 0].set_title('SOFA-1评分分布')
    axes[0, 0].grid(True, alpha=0.3)

    # SOFA-2评分分布
    axes[0, 1].hist(df['sofa2_score'], bins=25, alpha=0.7, color='red', edgecolor='black')
    axes[0, 1].set_xlabel('SOFA-2评分')
    axes[0, 1].set_ylabel('患者数量')
    axes[0, 1].set_title('SOFA-2评分分布')
    axes[0, 1].grid(True, alpha=0.3)

    # 按生存状态的评分分布
    survivors = df[df['icu_mortality'] == 0]
    nonsurvivors = df[df['icu_mortality'] == 1]

    axes[1, 0].hist([survivors['sofa_score'], nonsurvivors['sofa_score']],
                    bins=25, alpha=0.7, label=['生存', '死亡'],
                    color=['green', 'red'], edgecolor='black')
    axes[1, 0].set_xlabel('SOFA-1评分')
    axes[1, 0].set_ylabel('患者数量')
    axes[1, 0].set_title('SOFA-1评分按生存状态分布')
    axes[1, 0].legend()
    axes[1, 0].grid(True, alpha=0.3)

    axes[1, 1].hist([survivors['sofa2_score'], nonsurvivors['sofa2_score']],
                    bins=25, alpha=0.7, label=['生存', '死亡'],
                    color=['green', 'red'], edgecolor='black')
    axes[1, 1].set_xlabel('SOFA-2评分')
    axes[1, 1].set_ylabel('患者数量')
    axes[1, 1].set_title('SOFA-2评分按生存状态分布')
    axes[1, 1].legend()
    axes[1, 1].grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig('sofa_score_distributions.png', dpi=300, bbox_inches='tight')
    print("💾 评分分布图已保存为 'sofa_score_distributions.png'")

def generate_summary_report(auc_results, df):
    """生成总结报告"""
    print("\n📋 总结报告")
    print("=" * 50)

    report = f"""
SOFA vs SOFA2 ICU生存预测性能分析报告
分析日期：{pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S')}
数据来源：MIMIC-IV v2.2数据库
分析师：Python sklearn分析

一、数据概况
- 总患者数：{len(df):,}
- ICU死亡数：{df['icu_mortality'].sum():,} ({df['icu_mortality'].mean()*100:.2f}%)
- 医院死亡数：{df['hospital_expire_flag'].sum():,} ({df['hospital_expire_flag'].mean()*100:.2f}%)

二、评分统计
SOFA-1：平均{df['sofa_score'].mean():.2f}分 (SD={df['sofa_score'].std():.2f})
SOFA-2：平均{df['sofa2_score'].mean():.2f}分 (SD={df['sofa2_score'].std():.2f})

三、预测性能（AUC）
ICU死亡率预测：
- SOFA-1: {auc_results['sofa_icu_auc']:.4f}
- SOFA-2: {auc_results['sofa2_icu_auc']:.4f}
- 提升：+{auc_results['sofa2_icu_auc'] - auc_results['sofa_icu_auc']:.4f}

医院死亡率预测：
- SOFA-1: {auc_results['sofa_hosp_auc']:.4f}
- SOFA-2: {auc_results['sofa2_hosp_auc']:.4f}
- 提升：+{auc_results['sofa2_hosp_auc'] - auc_results['sofa_hosp_auc']:.4f}

四、结论
{'✅ SOFA-2显示改进的预测性能' if auc_results['sofa2_icu_auc'] > auc_results['sofa_icu_auc'] else '❌ SOFA-2性能未显著改善'}

建议：
1. 在临床实践中优先采用SOFA-2标准
2. 基于SOFA-2更新ICU质量评估基准
3. 继续监测SOFA-2的长期临床效果
"""

    with open('sofa_vs_sofa2_auc_report.txt', 'w', encoding='utf-8') as f:
        f.write(report)

    print(report)
    print("\n💾 详细报告已保存为 'sofa_vs_sofa2_auc_report.txt'")

def main():
    """主函数"""
    print("🚀 SOFA vs SOFA2 ICU生存预测AUC分析")
    print("=" * 50)

    try:
        # 加载数据
        df = load_and_prepare_data()

        # 基础统计
        calculate_basic_statistics(df)

        # 计算AUC
        auc_results = calculate_auc_scores(df)

        # 统计检验
        perform_statistical_test(df, auc_results)

        # 绘制ROC曲线
        plot_roc_curves(df, auc_results)

        # 分析评分分布
        analyze_score_distributions(df)

        # 生成报告
        generate_summary_report(auc_results, df)

        print("\n✅ 分析完成！")
        print("📊 生成的文件：")
        print("  - sofa_vs_sofa2_roc_curves.png")
        print("  - sofa_score_distributions.png")
        print("  - sofa_vs_sofa2_auc_report.txt")

    except FileNotFoundError:
        print("❌ 错误：找不到CSV数据文件")
        print("💡 请先运行 generate_auc_data_csv.sql 并保存结果为 survival_auc_data.csv")
    except Exception as e:
        print(f"❌ 分析过程中出现错误：{e}")

if __name__ == "__main__":
    main()