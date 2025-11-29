#!/usr/bin/env python3
"""
深入分析我们与原文SOFA2结果差异的原因
重新解读原文的"sequential"含义，并对比我们的实现
"""

import pandas as pd
import numpy as np
from sklearn.metrics import roc_auc_score, roc_curve
import matplotlib.pyplot as plt
import seaborn as sns
import warnings
warnings.filterwarnings('ignore')

def analyze_our_vs_original_results():
    """分析我们的结果与原文的差异"""
    print("🎯 重新分析：我们 vs 原文SOFA2结果差异")
    print("=" * 60)

    # 原文和我们结果的对比
    results_comparison = {
        'Original_SOF1_AUC': [0.80, 0.79, 0.81],  # Single-stage, Meta-anal, Range
        'Original_SOF2_AUC': [0.81, 0.79, 0.81],  # Single-stage, Meta-anal, Range
        'Our_SOF1_AUC': [0.7905, 0.7852, 0.7955],  # Estimate, CI_low, CI_high
        'Our_SOF2_AUC': [0.7732, 0.7678, 0.7781],  # Estimate, CI_low, CI_high
    }

    df_comparison = pd.DataFrame(results_comparison)
    df_comparison.index = ['Estimate', 'CI_Low', 'CI_High']

    print("📊 结果对比表：")
    print(df_comparison)

    print("\n🔍 关键发现：")
    print("1. SOFA-1结果 ✅ 高度一致 (0.80 vs 0.7905)")
    print("2. SOFA-2结果 ❌ 明显偏低 (0.81 vs 0.7732)")
    print("3. 优劣关系完全相反：原文 SOFA2>SOFA1，我们 SOFA1>SOFA2")

def analyze_potential_causes():
    """分析可能的差异原因"""
    print("\n🔬 潜在差异原因分析：")
    print("=" * 60)

    potential_causes = {
        "1. 队列差异": {
            "原文": "10个国际队列，270,108患者，多中心",
            "我们": "MIMIC-IV单一队列，65,330患者，单中心",
            "影响": "不同ICU类型和患者群体可能影响评分分布"
        },
        "2. SOFA-2实现标准": {
            "原文": "基于JAMA 2025最新SOFA-2标准",
            "我们": "基于原文实现，但可能有细节差异",
            "影响": "评分阈值或器官系统定义可能不同"
        },
        "3. 时间窗口定义": {
            "原文": "ICU首日+/- 6小时时间窗口",
            "我们": "ICU首日-6小时到+24小时窗口",
            "影响": "不同的时间窗口可能影响评分计算"
        },
        "4. 数据处理方式": {
            "原文": "multi-stage meta-analysis",
            "我们": "single-stage pooled analysis",
            "影响": "统计学方法差异可能影响结果"
        },
        "5. 缺失数据处理": {
            "原文": "multiple imputation methods",
            "我们": "默认MIMIC-IV数据处理",
            "影响": "缺失值处理可能影响评分分布"
        }
    }

    for cause, details in potential_causes.items():
        print(f"\n{cause}:")
        for key, value in details.items():
            print(f"  {key}: {value}")

def load_and_analyze_our_data():
    """分析我们的数据特征"""
    print("\n📊 我们的数据特征分析：")
    print("=" * 60)

    # 读取现有数据
    df = pd.read_csv('survival_auc_data.csv')

    print(f"📋 数据概况：")
    print(f"  总患者数: {len(df):,}")
    print(f"  ICU死亡数: {df['icu_mortality'].sum():,} ({df['icu_mortality'].mean()*100:.2f}%)")
    print(f"  SOFA-1平均分: {df['sofa_score'].mean():.2f} ± {df['sofa_score'].std():.2f}")
    print(f"  SOFA-2平均分: {df['sofa2_score'].mean():.2f} ± {df['sofa2_score'].std():.2f}")

    # 评分分布分析
    print(f"\n📈 评分分布对比：")

    # SOFA-1分布
    sofa1_quartiles = df['sofa_score'].quantile([0.25, 0.5, 0.75])
    print(f"  SOFA-1: Q1={sofa1_quartiles[0.25]:.1f}, 中位数={sofa1_quartiles[0.5]:.1f}, Q3={sofa1_quartiles[0.75]:.1f}")

    # SOFA-2分布
    sofa2_quartiles = df['sofa2_score'].quantile([0.25, 0.5, 0.75])
    print(f"  SOFA-2: Q1={sofa2_quartiles[0.25]:.1f}, 中位数={sofa2_quartiles[0.5]:.1f}, Q3={sofa2_quartiles[0.75]:.1f}")

    # 重症患者分析
    sofa1_severe = (df['sofa_score'] >= 8).sum()
    sofa2_severe = (df['sofa2_score'] >= 8).sum()

    print(f"\n🏥 重症患者识别 (SOFA≥8)：")
    print(f"  SOFA-1重症: {sofa1_severe:,} ({sofa1_severe/len(df)*100:.2f}%)")
    print(f"  SOFA-2重症: {sofa2_severe:,} ({sofa2_severe/len(df)*100:.2f}%)")
    print(f"  重症识别差异: {sofa2_severe - sofa1_severe:+,} ({(sofa2_severe - sofa1_severe)/len(df)*100:+.2f}%)")

    return df

def analyze_score_components_separately(df):
    """分析SOFA评分的预测能力分解"""
    print("\n🔬 SOFA评分组件的预测能力分析：")
    print("=" * 60)

    # 按SOFA评分分层分析预测能力
    score_bins = [0, 2, 4, 6, 8, 10, 12, 15, 24]
    df['sofa1_bin'] = pd.cut(df['sofa_score'], bins=score_bins, include_lowest=True)
    df['sofa2_bin'] = pd.cut(df['sofa2_score'], bins=score_bins, include_lowest=True)

    print("📊 SOFA-1分层死亡率：")
    sofa1_mortality = df.groupby('sofa1_bin')['icu_mortality'].agg(['mean', 'count'])
    for bin_range, row in sofa1_mortality.iterrows():
        if pd.notna(bin_range):
            print(f"  {bin_range}: {row['mean']*100:.1f}% ({row['count']}例)")

    print("\n📊 SOFA-2分层死亡率：")
    sofa2_mortality = df.groupby('sofa2_bin')['icu_mortality'].agg(['mean', 'count'])
    for bin_range, row in sofa2_mortality.iterrows():
        if pd.notna(bin_range):
            print(f"  {bin_range}: {row['mean']*100:.1f}% ({row['count']}例)")

    # 分析不同评分区间的判别能力
    print("\n🎯 不同评分区间的判别能力：")

    # 计算每个评分阈值点的敏感性和特异性
    thresholds = range(1, 15)

    sofa1_stats = []
    sofa2_stats = []

    for threshold in thresholds:
        # SOFA-1
        tp1 = ((df['sofa_score'] >= threshold) & (df['icu_mortality'] == 1)).sum()
        fp1 = ((df['sofa_score'] >= threshold) & (df['icu_mortality'] == 0)).sum()
        fn1 = ((df['sofa_score'] < threshold) & (df['icu_mortality'] == 1)).sum()
        tn1 = ((df['sofa_score'] < threshold) & (df['icu_mortality'] == 0)).sum()

        if (tp1 + fn1) > 0 and (tn1 + fp1) > 0:
            sensitivity1 = tp1 / (tp1 + fn1)
            specificity1 = tn1 / (tn1 + fp1)
            sofa1_stats.append((threshold, sensitivity1, specificity1))

        # SOFA-2
        tp2 = ((df['sofa2_score'] >= threshold) & (df['icu_mortality'] == 1)).sum()
        fp2 = ((df['sofa2_score'] >= threshold) & (df['icu_mortality'] == 0)).sum()
        fn2 = ((df['sofa2_score'] < threshold) & (df['icu_mortality'] == 1)).sum()
        tn2 = ((df['sofa2_score'] < threshold) & (df['icu_mortality'] == 0)).sum()

        if (tp2 + fn2) > 0 and (tn2 + fp2) > 0:
            sensitivity2 = tp2 / (tp2 + fn2)
            specificity2 = tn2 / (tn2 + fp2)
            sofa2_stats.append((threshold, sensitivity2, specificity2))

    # 找到Youden指数最大的阈值
    if sofa1_stats and sofa2_stats:
        youden1 = [(t, s + sp - 1) for t, s, sp in sofa1_stats]
        youden2 = [(t, s + sp - 1) for t, s, sp in sofa2_stats]

        best_threshold1 = max(youden1, key=lambda x: x[1])
        best_threshold2 = max(youden2, key=lambda x: x[1])

        print(f"  SOFA-1最佳阈值: {best_threshold1[0]} (Youden指数: {best_threshold1[1]:.3f})")
        print(f"  SOFA-2最佳阈值: {best_threshold2[0]} (Youden指数: {best_threshold2[1]:.3f})")

def generate_hypothesis_report():
    """生成差异原因的假设报告"""
    print("\n📋 差异原因假设报告：")
    print("=" * 60)

    report = """
基于我们的分析，以下是最可能的差异原因：

🎯 主要假设1：SOFA-2组件评分标准差异
• 原文SOFA-2可能使用了不同的器官系统评分阈值
• 我们的心血管、呼吸、神经等系统评分可能与原文不完全一致
• 特别是心血管评分中的血管活性药物剂量阈值可能不同

🎯 主要假设2：时间窗口和数据处理差异
• 原文使用严格的ICU首日数据
• 我们的时间窗口可能包含了不同阶段的临床数据
• 缺失数据处理方式可能不同

🎯 主要假设3：队列特征差异
• MIMIC-IV患者群体可能与国际多中心队列不同
• ICU类型、疾病谱、治疗模式可能存在系统差异
• 原文的10个队列多样性可能带来不同的评分分布特征

🔍 验证建议：
1. 重新核对SOFA-2各器官系统的评分阈值定义
2. 对比我们与原文的评分分布特征
3. 考虑进行亚组分析验证不同患者群体的表现
"""

    print(report)

def main():
    """主函数"""
    print("🚀 SOFA-2差异原因深入分析")
    print("=" * 60)

    # 1. 对比结果
    analyze_our_vs_original_results()

    # 2. 分析潜在原因
    analyze_potential_causes()

    # 3. 分析我们的数据
    df = load_and_analyze_our_data()

    # 4. 分析评分组件
    analyze_score_components_separately(df)

    # 5. 生成假设报告
    generate_hypothesis_report()

    print("\n🎯 关键结论：")
    print("=" * 60)
    print("1. ✅ SOFA-1结果与原文高度一致，说明我们的方法基本正确")
    print("2. ❌ SOFA-2结果明显偏低，提示实现标准可能存在差异")
    print("3. 🔍 需要重点检查SOFA-2各器官系统的评分阈值定义")
    print("4. 📊 队列差异也可能是重要因素")
    print("5. 💡 下一步：详细核对SOFA-2实现标准与原文的一致性")

if __name__ == "__main__":
    main()