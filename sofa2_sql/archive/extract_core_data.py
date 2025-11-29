#!/usr/bin/env python3
"""
SOFA-1 vs SOFA-2 核心数据提取脚本
提取最基本的数据集供R/Python分析使用
"""

import pandas as pd
import numpy as np
import psycopg2
import os
from datetime import datetime

# 数据库连接配置
DB_CONFIG = {
    'host': '172.19.160.1',
    'port': 5432,
    'database': 'mimiciv',
    'user': 'postgres',
    'password': '188211'
}

# 输出目录
OUTPUT_DIR = '/mnt/f/SaAki_Sofa_benchmark/analysis_data'

def connect_to_database():
    """连接到PostgreSQL数据库"""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        print("✅ 数据库连接成功")
        return conn
    except Exception as e:
        print(f"❌ 数据库连接失败: {e}")
        return None

def extract_main_dataset(conn):
    """提取主数据集"""
    print("📊 提取主数据集...")

    query = """
    SELECT
        -- 基础标识符
        fds2.stay_id,
        fds2.subject_id,

        -- 时间信息
        fds2.icu_intime,
        fds2.icu_outtime,
        fds2.window_start_time as sofa2_window_start,
        fds2.window_end_time as sofa2_window_end,

        -- SOFA-1评分（来自官方sepsis3表）
        s3.sofa_score as sofa1_score,
        s3.respiration as sofa1_respiration,
        s3.coagulation as sofa1_coagulation,
        s3.liver as sofa1_liver,
        s3.cardiovascular as sofa1_cardiovascular,
        s3.cns as sofa1_cns,
        s3.renal as sofa1_renal,
        s3.suspected_infection_time as sofa1_infection_time,

        -- SOFA-2评分
        fds2.sofa2 as sofa2_score,
        fds2.respiratory as sofa2_respiratory,
        fds2.cardiovascular as sofa2_cardiovascular,
        fds2.liver as sofa2_liver,
        fds2.kidney as sofa2_kidney,
        fds2.brain as sofa2_brain,
        fds2.hemostasis as sofa2_hemostasis,

        -- 预后信息
        fds2.icu_mortality,
        fds2.hospital_expire_flag,
        fds2.icu_los_hours,
        fds2.icu_los_days,

        -- 患者基本信息
        fds2.age,
        fds2.gender,
        fds2.race,
        fds2.admission_type,
        fds2.severity_category,

        -- 脓毒症状态
        s3.sepsis3 as sofa1_sepsis,
        CASE WHEN fds2.sofa2 >= 2 AND EXISTS (
            SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
            WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
            LIMIT 1
        ) THEN true ELSE false END as sofa2_sepsis

    FROM mimiciv_derived.first_day_sofa2 fds2
    LEFT JOIN mimiciv_derived.sepsis3 s3 ON fds2.stay_id = s3.stay_id
    ORDER BY fds2.stay_id
    """

    df = pd.read_sql_query(query, conn)
    output_path = os.path.join(OUTPUT_DIR, 'sofa_comparison_main_dataset.csv')
    df.to_csv(output_path, index=False)
    print(f"✅ 主数据集已保存: {len(df)} 条记录 -> {output_path}")
    return df

def generate_summary_statistics(main_df):
    """生成汇总统计信息"""
    print("📊 生成汇总统计信息...")

    # 基础统计
    summary_stats = {
        'total_patients': main_df['stay_id'].nunique(),
        'sofa1_sepsis_patients': main_df[main_df['sofa1_sepsis'] == True]['stay_id'].nunique(),
        'sofa2_sepsis_patients': main_df[main_df['sofa2_sepsis'] == True]['stay_id'].nunique(),
        'both_sofa_complete': main_df[(main_df['sofa1_score'].notna()) & (main_df['sofa2_score'].notna())]['stay_id'].nunique(),
        'icu_mortality_rate': main_df['icu_mortality'].mean() * 100,
        'hospital_mortality_rate': main_df['hospital_expire_flag'].mean() * 100,
        'mean_icu_los_hours': main_df['icu_los_hours'].mean(),
        'mean_age': main_df['age'].mean(),
        'male_percentage': (main_df['gender'] == 'M').mean() * 100,
        'sofa1_mean_score': main_df['sofa1_score'].mean(),
        'sofa2_mean_score': main_df['sofa2_score'].mean(),
        'sofa1_median_score': main_df['sofa1_score'].median(),
        'sofa2_median_score': main_df['sofa2_score'].median(),
        'data_completeness_sofa1': (main_df['sofa1_score'].notna().mean() * 100),
        'data_completeness_sofa2': (main_df['sofa2_score'].notna().mean() * 100)
    }

    # AUC计算数据
    complete_df = main_df[(main_df['sofa1_score'].notna()) &
                        (main_df['sofa2_score'].notna()) &
                        (main_df['icu_mortality'].notna())].copy()

    if len(complete_df) > 0:
        try:
            from sklearn.metrics import roc_auc_score
            auc_sofa1 = roc_auc_score(complete_df['icu_mortality'], complete_df['sofa1_score'])
            auc_sofa2 = roc_auc_score(complete_df['icu_mortality'], complete_df['sofa2_score'])
            summary_stats['auc_sofa1'] = auc_sofa1
            summary_stats['auc_sofa2'] = auc_sofa2
        except ImportError:
            print("⚠️ scikit-learn未安装，跳过AUC计算")

    # 保存汇总统计
    summary_df = pd.DataFrame(list(summary_stats.items()), columns=['metric', 'value'])
    output_path = os.path.join(OUTPUT_DIR, 'summary_statistics.csv')
    summary_df.to_csv(output_path, index=False)
    print(f"✅ 汇总统计信息已保存 -> {output_path}")

    # 打印关键统计信息
    print(f"\n📋 关键统计信息:")
    print(f"   总患者数: {summary_stats['total_patients']:,}")
    print(f"   SOFA-1脓毒症患者: {summary_stats['sofa1_sepsis_patients']:,}")
    print(f"   SOFA-2脓毒症患者: {summary_stats['sofa2_sepsis_patients']:,}")
    print(f"   ICU死亡率: {summary_stats['icu_mortality_rate']:.2f}%")
    print(f"   住院死亡率: {summary_stats['hospital_mortality_rate']:.2f}%")
    print(f"   平均ICU住院时长: {summary_stats['mean_icu_los_hours']:.1f} 小时")
    print(f"   平均年龄: {summary_stats['mean_age']:.1f} 岁")
    print(f"   男性比例: {summary_stats['male_percentage']:.1f}%")
    print(f"   SOFA-1平均评分: {summary_stats['sofa1_mean_score']:.2f}")
    print(f"   SOFA-2平均评分: {summary_stats['sofa2_mean_score']:.2f}")
    if 'auc_sofa1' in summary_stats:
        print(f"   SOFA-1 AUC: {summary_stats['auc_sofa1']:.4f}")
        print(f"   SOFA-2 AUC: {summary_stats['auc_sofa2']:.4f}")

    return summary_df

def extract_score_distributions(conn):
    """提取评分分布数据"""
    print("📊 提取评分分布数据...")

    distribution_data = []

    # SOFA-1和SOFA-2总分分布
    for score_type, table, score_col in [
        ('SOFA1_Total', 'mimiciv_derived.sepsis3', 'sofa_score'),
        ('SOFA2_Total', 'mimiciv_derived.first_day_sofa2', 'sofa2')
    ]:
        query = f"SELECT {score_col} as score_value, COUNT(*) as frequency FROM {table} WHERE {score_col} IS NOT NULL GROUP BY {score_col}"
        df = pd.read_sql_query(query, conn)
        df['score_type'] = score_type
        distribution_data.append(df)

    # 器官系统评分分布
    organ_systems = [
        ('SOFA1_Resp', 'mimiciv_derived.sepsis3', 'respiration'),
        ('SOFA2_Resp', 'mimiciv_derived.first_day_sofa2', 'respiratory'),
        ('SOFA1_CV', 'mimiciv_derived.sepsis3', 'cardiovascular'),
        ('SOFA2_CV', 'mimiciv_derived.first_day_sofa2', 'cardiovascular'),
        ('SOFA1_Liver', 'mimiciv_derived.sepsis3', 'liver'),
        ('SOFA2_Liver', 'mimiciv_derived.first_day_sofa2', 'liver'),
        ('SOFA1_Renal', 'mimiciv_derived.sepsis3', 'renal'),
        ('SOFA2_Renal', 'mimiciv_derived.first_day_sofa2', 'kidney'),
        ('SOFA1_CNS', 'mimiciv_derived.sepsis3', 'cns'),
        ('SOFA2_Brain', 'mimiciv_derived.first_day_sofa2', 'brain'),
        ('SOFA1_Coag', 'mimiciv_derived.sepsis3', 'coagulation'),
        ('SOFA2_Hemostasis', 'mimiciv_derived.first_day_sofa2', 'hemostasis')
    ]

    for score_type, table, score_col in organ_systems:
        query = f"SELECT {score_col} as score_value, COUNT(*) as frequency FROM {table} WHERE {score_col} IS NOT NULL GROUP BY {score_col}"
        df = pd.read_sql_query(query, conn)
        df['score_type'] = score_type
        distribution_data.append(df)

    # 合并所有分布数据
    final_df = pd.concat(distribution_data, ignore_index=True)
    final_df = final_df[['score_type', 'score_value', 'frequency']].sort_values(['score_type', 'score_value'])

    output_path = os.path.join(OUTPUT_DIR, 'sofa_score_distributions.csv')
    final_df.to_csv(output_path, index=False)
    print(f"✅ 评分分布数据已保存: {len(final_df)} 条记录 -> {output_path}")
    return final_df

def create_readme_file():
    """创建数据说明文件"""
    readme_content = """# SOFA-1 vs SOFA-2 分析数据集

## 数据文件说明

### 主要数据集

1. **sofa_comparison_main_dataset.csv** - 主要分析数据集
   - 包含所有患者的SOFA-1和SOFA-2评分
   - 患者基本信息、预后信息、脓毒症状态
   - 时间信息、器官系统评分

2. **summary_statistics.csv** - 汇总统计信息
   - 基本统计指标
   - AUC值（如果可计算）
   - 数据完整性指标

3. **sofa_score_distributions.csv** - 评分分布数据
   - SOFA-1和SOFA-2总分分布
   - 各器官系统评分分布

## 主要变量说明

### 基础标识符
- `stay_id`: ICU住院ID
- `subject_id`: 患者ID

### SOFA评分
- `sofa1_score`: SOFA-1总分
- `sofa2_score`: SOFA-2总分
- 器官系统评分: respiratory, cardiovascular, liver, renal, cns/brain, coagulation/hemostasis

### 预后信息
- `icu_mortality`: ICU死亡率 (0/1)
- `hospital_expire_flag`: 住院死亡率 (0/1)
- `icu_los_hours`: ICU住院时长（小时）

### 脓毒症状态
- `sofa1_sepsis`: 基于SOFA-1的脓毒症状态
- `sofa2_sepsis`: 基于SOFA-2的脓毒症状态

## 数据来源
- 数据库: MIMIC-IV v2.2
- 表: mimiciv_derived.sepsis3, mimiciv_derived.first_day_sofa2
- 提取时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

## 分析建议

1. **AUC分析**: 使用icu_mortality作为结局变量
2. **脓毒症对比**: 比较sofa1_sepsis vs sofa2_sepsis
3. **分布分析**: 使用sofa_score_distributions.csv数据
4. **亚组分析**: 按年龄、性别、疾病严重度分层

## 注意事项
- 数据已去重，每个stay_id只出现一次
- 缺失值处理请根据具体分析需求
- 时间变量已转换为datetime格式
"""

    readme_path = os.path.join(OUTPUT_DIR, 'README.md')
    with open(readme_path, 'w', encoding='utf-8') as f:
        f.write(readme_content)
    print(f"✅ 数据说明文件已创建 -> {readme_path}")

def main():
    """主函数"""
    print("🚀 开始提取SOFA-1 vs SOFA-2核心数据...")
    print(f"📁 输出目录: {OUTPUT_DIR}")

    # 创建输出目录
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 连接数据库
    conn = connect_to_database()
    if not conn:
        return

    try:
        # 提取主数据集
        main_df = extract_main_dataset(conn)

        # 生成汇总统计
        summary_df = generate_summary_statistics(main_df)

        # 提取评分分布
        distribution_df = extract_score_distributions(conn)

        # 创建说明文件
        create_readme_file()

        print(f"\n✅ 数据提取完成！")
        print(f"📁 所有数据已保存到: {OUTPUT_DIR}")
        print(f"📊 生成的文件:")

        files = os.listdir(OUTPUT_DIR)
        for file in files:
            print(f"   - {file}")

    except Exception as e:
        print(f"❌ 数据提取过程中出现错误: {e}")

    finally:
        conn.close()
        print("🔌 数据库连接已关闭")

if __name__ == "__main__":
    main()