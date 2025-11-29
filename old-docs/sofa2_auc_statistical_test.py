#!/usr/bin/env python3
"""
SOFA-1 vs SOFA-2 AUC差异的统计学检验
使用bootstrap方法计算AUC差异的置信区间和p值
"""

import pandas as pd
import numpy as np
from sklearn.metrics import roc_auc_score, roc_curve
import matplotlib.pyplot as plt
import seaborn as sns
from scipy import stats
import warnings
warnings.filterwarnings('ignore')

def load_data():
    """加载数据"""
    df = pd.read_csv('survival_auc_data.csv')

    # 数据清洗
    df = df.dropna(subset=['sofa_score', 'sofa2_score', 'icu_mortality'])
    df['icu_mortality'] = df['icu_mortality'].astype(int)

    print(f"✅ 数据加载完成：{len(df)}名患者")
    print(f"   ICU死亡率：{df['icu_mortality'].mean()*100:.2f}%")

    return df

def calculate_bootstrap_auc_difference(df, n_bootstrap=2000):
    """使用bootstrap方法计算AUC差异的统计检验"""
    print(f"\n🔬 Bootstrap统计检验 (n={n_bootstrap})")
    print("=" * 60)

    np.random.seed(42)  # 设置随机种子确保结果可重现

    # 计算原始AUC
    auc_sofa1_orig = roc_auc_score(df['icu_mortality'], df['sofa_score'])
    auc_sofa2_orig = roc_auc_score(df['icu_mortality'], df['sofa2_score'])
    diff_orig = auc_sofa2_orig - auc_sofa1_orig

    print(f"📊 原始AUC：")
    print(f"   SOFA-1: {auc_sofa1_orig:.4f}")
    print(f"   SOFA-2: {auc_sofa2_orig:.4f}")
    print(f"   差异 (SOFA2-SOFA1): {diff_orig:+.4f}")

    # Bootstrap重采样
    bootstrap_diffs = []
    bootstrap_sofa1_aucs = []
    bootstrap_sofa2_aucs = []

    n_patients = len(df)
    n_pos = df['icu_mortality'].sum()
    n_neg = n_patients - n_pos

    print(f"\n🔄 开始Bootstrap重采样...")

    for i in range(n_bootstrap):
        # 重采样
        bootstrap_indices = np.random.choice(n_patients, size=n_patients, replace=True)
        bootstrap_df = df.iloc[bootstrap_indices].copy()

        # 检查是否有足够的阳性和阴性样本
        if bootstrap_df['icu_mortality'].sum() == 0 or bootstrap_df['icu_mortality'].sum() == n_patients:
            continue

        # 计算bootstrap AUC
        auc_sofa1_boot = roc_auc_score(bootstrap_df['icu_mortality'], bootstrap_df['sofa_score'])
        auc_sofa2_boot = roc_auc_score(bootstrap_df['icu_mortality'], bootstrap_df['sofa2_score'])

        bootstrap_sofa1_aucs.append(auc_sofa1_boot)
        bootstrap_sofa2_aucs.append(auc_sofa2_boot)
        bootstrap_diffs.append(auc_sofa2_boot - auc_sofa1_boot)

        # 进度显示
        if (i + 1) % 500 == 0:
            print(f"   完成 {i + 1}/{n_bootstrap} 次重采样")

    print(f"✅ Bootstrap完成：{len(bootstrap_diffs)}次有效重采样")

    # 计算置信区间
    bootstrap_diffs = np.array(bootstrap_diffs)
    bootstrap_sofa1_aucs = np.array(bootstrap_sofa1_aucs)
    bootstrap_sofa2_aucs = np.array(bootstrap_sofa2_aucs)

    # 95%置信区间
    ci_95_low, ci_95_high = np.percentile(bootstrap_diffs, [2.5, 97.5])
    ci_90_low, ci_90_high = np.percentile(bootstrap_diffs, [5.0, 95.0])

    # 计算p值
    if diff_orig >= 0:
        p_value = np.mean(bootstrap_diffs < 0)
    else:
        p_value = np.mean(bootstrap_diffs > 0)

    # 双尾p值
    p_value_two_sided = 2 * min(p_value, 1 - p_value)

    print(f"\n📈 Bootstrap结果：")
    print(f"   SOFA-1 AUC: {np.mean(bootstrap_sofa1_aucs):.4f} ({np.percentile(bootstrap_sofa1_aucs, 2.5):.4f}-{np.percentile(bootstrap_sofa1_aucs, 97.5):.4f})")
    print(f"   SOFA-2 AUC: {np.mean(bootstrap_sofa2_aucs):.4f} ({np.percentile(bootstrap_sofa2_aucs, 2.5):.4f}-{np.percentile(bootstrap_sofa2_aucs, 97.5):.4f})")

    print(f"\n🎯 AUC差异统计检验：")
    print(f"   观测差异: {diff_orig:+.4f}")
    print(f"   95% CI: [{ci_95_low:+.4f}, {ci_95_high:+.4f}]")
    print(f"   90% CI: [{ci_90_low:+.4f}, {ci_90_high:+.4f}]")
    print(f"   单尾p值: {p_value:.4f}")
    print(f"   双尾p值: {p_value_two_sided:.4f}")

    # 统计学显著性判断
    alpha = 0.05
    if p_value_two_sided < alpha:
        if diff_orig > 0:
            print(f"\n✅ 结果显著：SOFA-2显著优于SOFA-1 (p={p_value_two_sided:.4f})")
        else:
            print(f"\n❌ 结果显著：SOFA-2显著劣于SOFA-1 (p={p_value_two_sided:.4f})")
    else:
        print(f"\n➖️ 结果不显著：SOFA-1和SOFA-2无统计学差异 (p={p_value_two_sided:.4f})")

    return {
        'auc_sofa1': auc_sofa1_orig,
        'auc_sofa2': auc_sofa2_orig,
        'diff': diff_orig,
        'bootstrap_diffs': bootstrap_diffs,
        'bootstrap_sofa1_aucs': bootstrap_sofa1_aucs,
        'bootstrap_sofa2_aucs': bootstrap_sofa2_aucs,
        'ci_95': (ci_95_low, ci_95_high),
        'ci_90': (ci_90_low, ci_90_high),
        'p_value': p_value_two_sided
    }

def delong_test(y_true, y_score1, y_score2):
    """
    DeLong检验：比较两个相关ROC曲线的AUC差异
    这是AUC比较的更精确方法
    """
    def compute_auc_variance(y_true, y_score):
        """计算AUC的方差（使用DeLong方法）"""
        n = len(y_true)
        n_pos = np.sum(y_true == 1)
        n_neg = n - n_pos

        # 排序
        order = np.argsort(y_score)[::-1]
        y_true_sorted = y_true[order]
        y_score_sorted = y_score[order]

        # 计算结构化变量
        V10 = np.cumsum(y_true_sorted) - y_true_sorted
        V11 = np.cumsum(1 - y_true_sorted) - (1 - y_true_sorted)

        # 计算AUC方差
        auc = np.sum(V10 * y_true_sorted) / (n_pos * n_neg)

        S1 = np.sum(V10 * y_true_sorted) / (n_pos * n_neg)
        S2 = np.sum(V11 * (1 - y_true_sorted)) / (n_pos * n_neg)

        var_auc = (S1 - auc**2) / n_pos + (S2 - auc**2) / n_neg

        return auc, var_auc

    # 计算每个模型的AUC和方差
    auc1, var1 = compute_auc_variance(y_true, y_score1)
    auc2, var2 = compute_auc_variance(y_true, y_score2)

    # 计算协方差
    order = np.lexsort((y_score1, y_score2))[::-1]

    # 简化的协方差计算
    rank1 = stats.rankdata(y_score1)
    rank2 = stats.rankdata(y_score2)

    n = len(y_true)
    n_pos = np.sum(y_true == 1)
    n_neg = n - n_pos

    # 计算协方差的近似方法
    cov = np.cov(rank1, rank2)[0, 1] * (n_pos * n_neg) / (n**2 * (n-1))

    # 计算差异的统计量
    diff = auc2 - auc1
    se_diff = np.sqrt(var1 + var2 - 2 * cov)

    z_score = diff / se_diff
    p_value = 2 * (1 - stats.norm.cdf(abs(z_score)))

    return {
        'auc1': auc1,
        'auc2': auc2,
        'diff': diff,
        'se_diff': se_diff,
        'z_score': z_score,
        'p_value': p_value
    }

def plot_bootstrap_results(results):
    """绘制Bootstrap结果图"""
    print(f"\n📊 生成Bootstrap结果图...")

    fig, axes = plt.subplots(2, 2, figsize=(15, 12))

    # 1. AUC差异分布直方图
    axes[0, 0].hist(results['bootstrap_diffs'], bins=50, alpha=0.7, color='skyblue', edgecolor='black')
    axes[0, 0].axvline(results['diff'], color='red', linewidth=2, label=f'观测差异: {results["diff"]:+.4f}')
    axes[0, 0].axvline(0, color='black', linestyle='--', linewidth=1, label='零差异线')

    # 添加置信区间
    axes[0, 0].axvspan(results['ci_95'][0], results['ci_95'][1], alpha=0.2, color='red',
                       label=f'95% CI: [{results["ci_95"][0]:+.3f}, {results["ci_95"][1]:+.3f}]')

    axes[0, 0].set_xlabel('AUC差异 (SOFA2 - SOFA1)')
    axes[0, 0].set_ylabel('频次')
    axes[0, 0].set_title('Bootstrap AUC差异分布')
    axes[0, 0].legend()
    axes[0, 0].grid(True, alpha=0.3)

    # 2. 两个AUC的联合分布
    axes[0, 1].scatter(results['bootstrap_sofa1_aucs'], results['bootstrap_sofa2_aucs'],
                       alpha=0.5, s=1, color='blue')
    axes[0, 1].plot([0.75, 0.82], [0.75, 0.82], 'r--', linewidth=1, label='相等线')
    axes[0, 1].scatter([results['auc_sofa1']], [results['auc_sofa2']],
                       color='red', s=100, marker='*', label='观测值', zorder=5)

    axes[0, 1].set_xlabel('SOFA-1 AUC')
    axes[0, 1].set_ylabel('SOFA-2 AUC')
    axes[0, 1].set_title('Bootstrap AUC联合分布')
    axes[0, 1].legend()
    axes[0, 1].grid(True, alpha=0.3)
    axes[0, 1].set_xlim(0.75, 0.82)
    axes[0, 1].set_ylim(0.75, 0.82)

    # 3. 置信区间比较图
    methods = ['SOFA-1', 'SOFA-2']
    means = [results['auc_sofa1'], results['auc_sofa2']]
    cis = [
        (np.percentile(results['bootstrap_sofa1_aucs'], 2.5), np.percentile(results['bootstrap_sofa1_aucs'], 97.5)),
        (np.percentile(results['bootstrap_sofa2_aucs'], 2.5), np.percentile(results['bootstrap_sofa2_aucs'], 97.5))
    ]

    x_pos = np.arange(len(methods))
    colors = ['blue', 'red']

    axes[1, 0].bar(x_pos, means, color=colors, alpha=0.7, yerr=[
        [means[i] - cis[i][0] for i in range(len(means))],
        [cis[i][1] - means[i] for i in range(len(means))]
    ], capsize=5)

    axes[1, 0].set_xlabel('评分系统')
    axes[1, 0].set_ylabel('AUC')
    axes[1, 0].set_title('AUC估计值及95%置信区间')
    axes[1, 0].set_xticks(x_pos)
    axes[1, 0].set_xticklabels(methods)
    axes[1, 0].set_ylim(0.75, 0.82)
    axes[1, 0].grid(True, alpha=0.3, axis='y')

    # 添加数值标签
    for i, (mean, ci) in enumerate(zip(means, cis)):
        axes[1, 0].text(i, mean + 0.002, f'{mean:.4f}\n[{ci[0]:.3f}, {ci[1]:.3f}]',
                       ha='center', va='bottom', fontweight='bold')

    # 4. p值和统计显著性
    axes[1, 1].axis('off')

    significance_text = f"""
📊 统计检验结果摘要
════════════════════════════

原始结果：
• SOFA-1 AUC: {results['auc_sofa1']:.4f}
• SOFA-2 AUC: {results['auc_sofa2']:.4f}
• AUC差异: {results['diff']:+.4f}

Bootstrap检验：
• 95%置信区间: [{results['ci_95'][0]:+.4f}, {results['ci_95'][1]:+.4f}]
• 双尾p值: {results['p_value']:.4f}

统计学结论：
{ "✅ SOFA-2显著优于SOFA-1" if results['diff'] > 0 and results['p_value'] < 0.05 else
  "❌ SOFA-2显著劣于SOFA-1" if results['diff'] < 0 and results['p_value'] < 0.05 else
  "➖️ 两种评分系统无显著差异" }

解释：{ "SOFA-2显示了统计显著的改进" if results['diff'] > 0 and results['p_value'] < 0.05 else
        "SOFA-2显示统计显著的性能下降" if results['diff'] < 0 and results['p_value'] < 0.05 else
        "两种评分系统的预测性能无统计学差异" }
    """

    axes[1, 1].text(0.1, 0.5, significance_text, fontsize=12,
                   verticalalignment='center', fontfamily='monospace')

    plt.tight_layout()
    plt.savefig('sofa_auc_statistical_test.png', dpi=300, bbox_inches='tight')
    print("💾 统计检验结果图已保存为 'sofa_auc_statistical_test.png'")

def generate_statistical_report(results, delong_result=None):
    """生成统计检验报告"""
    print(f"\n📋 生成统计检验报告...")

    report = f"""
SOFA-1 vs SOFA-2 AUC差异统计学检验报告
═══════════════════════════════════════════

分析日期：2025-11-21
数据来源：MIMIC-IV v2.2数据库
分析样本：{len(pd.read_csv('survival_auc_data.csv')):,}名ICU患者
分析方法：Bootstrap重采样 (n=2000) + DeLong检验

📊 原始结果对比
────────────────────────────────
• SOFA-1 AUC: {results['auc_sofa1']:.4f}
• SOFA-2 AUC: {results['auc_sofa2']:.4f}
• AUC差异 (SOFA2-SOFA1): {results['diff']:+.4f}

🔬 Bootstrap统计检验
────────────────────────────────
• 重采样次数: 2000
• AUC差异均值: {np.mean(results['bootstrap_diffs']):+.4f}
• AUC差异标准差: {np.std(results['bootstrap_diffs']):.4f}
• 95%置信区间: [{results['ci_95'][0]:+.4f}, {results['ci_95'][1]:+.4f}]
• 90%置信区间: [{results['ci_90'][0]:+.4f}, {results['ci_90'][1]:+.4f}]
• 双尾p值: {results['p_value']:.6f}

🎯 统计学结论
────────────────────────────────
显著性水平: α = 0.05
检验结果: {"拒绝原假设" if results['p_value'] < 0.05 else "不能拒绝原假设"}

"""

    if results['diff'] > 0 and results['p_value'] < 0.05:
        report += """✅ SOFA-2显著优于SOFA-1

结论：在统计显著性水平下，SOFA-2评分系统对ICU死亡率的预测性能显著优于传统SOFA-1评分系统。
建议：在临床实践中优先考虑采用SOFA-2评分系统。
"""
    elif results['diff'] < 0 and results['p_value'] < 0.05:
        report += """❌ SOFA-2显著劣于SOFA-1

结论：在统计显著性水平下，SOFA-2评分系统对ICU死亡率的预测性能显著差于传统SOFA-1评分系统。
建议：需要重新评估SOFA-2的实现标准或适用性。
"""
    else:
        report += """➖️ SOFA-1和SOFA-2无统计学差异

结论：虽然观察到AUC差异，但这种差异在统计学上不显著。
建议：两种评分系统在预测性能上可以认为是等效的。
"""

    report += f"""
📈 临床意义评估
────────────────────────────────
• 绝对差异: {abs(results['diff']):.4f}
• 相对差异: {abs(results['diff'])/results['auc_sofa1']*100:.2f}%
• 临床相关性: {"高" if abs(results['diff']) > 0.05 else "中" if abs(results['diff']) > 0.02 else "低"}

🔬 方法论说明
────────────────────────────────
1. Bootstrap方法：通过重采样评估AUC差异的抽样分布
2. 置信区间：95%和90%置信区间提供差异的精度估计
3. p值：双尾检验评估差异的统计学显著性
4. 临床解释：结合统计学和临床实践意义进行综合评估

📋 报告生成时间：{pd.Timestamp.now().strftime('%Y-%m-%d %H:%M:%S')}
📋 分析工具：Python scikit-learn + Bootstrap方法
"""

    with open('sofa_auc_statistical_test_report.txt', 'w', encoding='utf-8') as f:
        f.write(report)

    print(report)
    print("💾 详细报告已保存为 'sofa_auc_statistical_test_report.txt'")

def main():
    """主函数"""
    print("🚀 SOFA-1 vs SOFA-2 AUC差异统计学检验")
    print("=" * 60)

    try:
        # 1. 加载数据
        df = load_data()

        # 2. Bootstrap统计检验
        results = calculate_bootstrap_auc_difference(df, n_bootstrap=2000)

        # 3. DeLong检验（如果可能）
        print(f"\n🔬 DeLong检验...")
        try:
            delong_result = delong_test(df['icu_mortality'].values,
                                      df['sofa_score'].values,
                                      df['sofa2_score'].values)
            print(f"   DeLong AUC1: {delong_result['auc1']:.4f}")
            print(f"   DeLong AUC2: {delong_result['auc2']:.4f}")
            print(f"   DeLong 差异: {delong_result['diff']:+.4f}")
            print(f"   DeLong Z值: {delong_result['z_score']:.4f}")
            print(f"   DeLong p值: {delong_result['p_value']:.6f}")
        except Exception as e:
            print(f"   DeLong检验失败: {e}")
            delong_result = None

        # 4. 绘制结果图
        plot_bootstrap_results(results)

        # 5. 生成报告
        generate_statistical_report(results, delong_result)

        print(f"\n✅ 统计检验完成！")
        print("📊 生成文件：")
        print("  - sofa_auc_statistical_test.png")
        print("  - sofa_auc_statistical_test_report.txt")

    except Exception as e:
        print(f"❌ 检验过程出错：{e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()