#!/usr/bin/env python3
"""
SOFA-1 vs SOFA-2 数据提取脚本
从MIMIC-IV数据库中提取所有相关数据供后续分析使用
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
        fds2.hadm_id,

        -- 时间信息
        fds2.icu_intime,
        fds2.icu_outtime,
        fds2.window_start_time as sofa2_window_start,
        fds2.window_end_time as sofa2_window_end,
        fds2.first_measurement_time,
        fds2.last_measurement_time,

        -- SOFA-1评分（来自官方sepsis3表）
        s3.sofa_score as sofa1_score,
        s3.respiration as sofa1_respiration,
        s3.coagulation as sofa1_coagulation,
        s3.liver as sofa1_liver,
        s3.cardiovascular as sofa1_cardiovascular,
        s3.cns as sofa1_cns,
        s3.renal as sofa1_renal,
        s3.antibiotic_time,
        s3.culture_time,
        s3.suspected_infection_time,
        s3.sofa_time as sofa1_time,

        -- SOFA-2评分
        fds2.sofa2 as sofa2_score,
        fds2.respiratory as sofa2_respiratory,
        fds2.cardiovascular as sofa2_cardiovascular,
        fds2.liver as sofa2_liver,
        fds2.kidney as sofa2_kidney,
        fds2.brain as sofa2_brain,
        fds2.hemostasis as sofa2_hemostasis,
        fds2.sofa2_icu_admission as sofa2_icu_admission_score,

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
        fds2.admission_location,
        fds2.severity_category,
        fds2.organ_failure_flag,
        fds2.failing_organs_count,
        fds2.data_completeness,
        fds2.trend_first_day,

        -- 脓毒症状态
        s3.sepsis3 as sofa1_sepsis,
        CASE WHEN fds2.sofa2 >= 2 AND EXISTS (
            SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
            WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
            LIMIT 1
        ) THEN true ELSE false END as sofa2_sepsis,

        -- 感染状态
        CASE WHEN EXISTS (
            SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
            WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
            LIMIT 1
        ) THEN true ELSE false END as has_suspected_infection

    FROM mimiciv_derived.first_day_sofa2 fds2
    LEFT JOIN mimiciv_derived.sepsis3 s3 ON fds2.stay_id = s3.stay_id
    ORDER BY fds2.stay_id
    """

    df = pd.read_sql_query(query, conn)
    output_path = os.path.join(OUTPUT_DIR, 'sofa_comparison_main_dataset.csv')
    df.to_csv(output_path, index=False)
    print(f"✅ 主数据集已保存: {len(df)} 条记录 -> {output_path}")
    return df

def extract_sofa1_sepsis_patients(conn):
    """提取SOFA-1脓毒症患者数据"""
    print("📊 提取SOFA-1脓毒症患者数据...")

    query = """
    SELECT
        s3.stay_id,
        s3.subject_id,
        s3.sofa_score as sofa1_total,
        s3.respiration as sofa1_resp,
        s3.coagulation as sofa1_coag,
        s3.liver as sofa1_liver,
        s3.cardiovascular as sofa1_cv,
        s3.cns as sofa1_cns,
        s3.renal as sofa1_renal,
        fds2.icu_mortality,
        s3.hospital_expire_flag,
        fds2.icu_los_hours,
        fds2.age,
        fds2.gender,
        fds2.race,
        fds2.admission_type,
        fds2.severity_category,
        fds2.organ_failure_flag,
        fds2.failing_organs_count,
        s3.antibiotic_time,
        s3.culture_time,
        s3.suspected_infection_time,
        s3.sofa_time
    FROM mimiciv_derived.sepsis3 s3
    JOIN mimiciv_derived.first_day_sofa2 fds2 ON s3.stay_id = fds2.stay_id
    WHERE s3.sepsis3 = true
    ORDER BY s3.stay_id
    """

    df = pd.read_sql_query(query, conn)
    output_path = os.path.join(OUTPUT_DIR, 'sofa1_sepsis_patients.csv')
    df.to_csv(output_path, index=False)
    print(f"✅ SOFA-1脓毒症患者数据已保存: {len(df)} 条记录 -> {output_path}")
    return df

def extract_sofa2_sepsis_patients(conn):
    """提取SOFA-2脓毒症患者数据"""
    print("📊 提取SOFA-2脓毒症患者数据...")

    query = """
    SELECT DISTINCT
        fds2.stay_id,
        fds2.subject_id,
        fds2.sofa2 as sofa2_total,
        fds2.respiratory as sofa2_resp,
        fds2.cardiovascular as sofa2_cv,
        fds2.liver as sofa2_liver,
        fds2.kidney as sofa2_kidney,
        fds2.brain as sofa2_brain,
        fds2.hemostasis as sofa2_hemostasis,
        fds2.icu_mortality,
        fds2.hospital_expire_flag,
        fds2.icu_los_hours,
        fds2.age,
        fds2.gender,
        fds2.race,
        fds2.admission_type,
        fds2.severity_category,
        fds2.organ_failure_flag,
        fds2.failing_organs_count,
        fds2.window_start_time,
        fds2.window_end_time,
        fds2.icu_intime,
        fds2.icu_outtime
    FROM mimiciv_derived.first_day_sofa2 fds2
    WHERE fds2.sofa2 >= 2
        AND EXISTS (
            SELECT 1 FROM mimiciv_derived.suspicion_of_infection soi
            WHERE soi.stay_id = fds2.stay_id AND soi.suspected_infection = 1
            LIMIT 1
        )
        AND fds2.stay_id IS NOT NULL
    ORDER BY fds2.stay_id
    """

    df = pd.read_sql_query(query, conn)
    output_path = os.path.join(OUTPUT_DIR, 'sofa2_sepsis_patients.csv')
    df.to_csv(output_path, index=False)
    print(f"✅ SOFA-2脓毒症患者数据已保存: {len(df)} 条记录 -> {output_path}")
    return df

def extract_suspicion_infection_data(conn):
    """提取可疑感染数据"""
    print("📊 提取可疑感染数据...")

    query = """
    SELECT DISTINCT
        soi.stay_id,
        soi.suspected_infection_time,
        soi.suspected_infection,
        soi.specimen,
        soi.antibiotic_time,
        soi.culture_time
    FROM mimiciv_derived.suspicion_of_infection soi
    WHERE soi.stay_id IN (
        SELECT stay_id FROM mimiciv_derived.first_day_sofa2
    )
    ORDER BY soi.stay_id, soi.suspected_infection_time
    """

    df = pd.read_sql_query(query, conn)
    output_path = os.path.join(OUTPUT_DIR, 'suspicion_of_infection_data.csv')
    df.to_csv(output_path, index=False)
    print(f"✅ 可疑感染数据已保存: {len(df)} 条记录 -> {output_path}")
    return df

def extract_icu_basic_info(conn):
    """提取ICU基本信息"""
    print("📊 提取ICU基本信息...")

    query = """
    SELECT
        stay_id,
        subject_id,
        hadm_id,
        intime,
        outtime,
        los_icu_days,
        first_careunit,
        last_careunit,
        admission_type,
        CASE WHEN expire_flag = 1 THEN true ELSE false END as icu_expire_flag
    FROM mimiciv_icu.icustays
    WHERE stay_id IN (
        SELECT stay_id FROM mimiciv_derived.first_day_sofa2
    )
    ORDER BY stay_id
    """

    df = pd.read_sql_query(query, conn)
    # 计算住院时长（小时）
    df['los_icu_hours'] = (df['outtime'] - df['intime']).dt.total_seconds() / 3600

    output_path = os.path.join(OUTPUT_DIR, 'icu_stays_basic_info.csv')
    df.to_csv(output_path, index=False)
    print(f"✅ ICU基本信息已保存: {len(df)} 条记录 -> {output_path}")
    return df

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

def generate_data_quality_report(main_df, sofa1_df, sofa2_df):
    """生成数据质量报告"""
    print("📊 生成数据质量报告...")

    report_data = [
        ['Total_Patients', main_df['stay_id'].nunique(), 'Unique ICU stays in dataset'],
        ['SOFA1_Complete', main_df[main_df['sofa1_score'].notna()]['stay_id'].nunique(), 'Patients with complete SOFA-1 scores'],
        ['SOFA2_Complete', main_df[main_df['sofa2_score'].notna()]['stay_id'].nunique(), 'Patients with complete SOFA-2 scores'],
        ['Both_Complete', main_df[(main_df['sofa1_score'].notna()) & (main_df['sofa2_score'].notna())]['stay_id'].nunique(), 'Patients with both SOFA-1 and SOFA-2 scores'],
        ['SOFA1_Sepsis', main_df[main_df['sofa1_sepsis'] == True]['stay_id'].nunique(), 'SOFA-1 defined sepsis patients'],
        ['SOFA2_Sepsis', main_df[main_df['sofa2_sepsis'] == True]['stay_id'].nunique(), 'SOFA-2 defined sepsis patients'],
        ['Both_Sepsis', main_df[(main_df['sofa1_sepsis'] == True) & (main_df['sofa2_sepsis'] == True)]['stay_id'].nunique(), 'Patients defined as sepsis by both methods'],
        ['ICU_Deaths', main_df[main_df['icu_mortality'] == 1]['stay_id'].nunique(), 'ICU mortality cases'],
        ['Hospital_Deaths', main_df[main_df['hospital_expire_flag'] == 1]['stay_id'].nunique(), 'Hospital mortality cases']
    ]

    report_df = pd.DataFrame(report_data, columns=['metric', 'value', 'description'])

    output_path = os.path.join(OUTPUT_DIR, 'data_quality_report.csv')
    report_df.to_csv(output_path, index=False)
    print(f"✅ 数据质量报告已保存 -> {output_path}")
    return report_df

def generate_summary_statistics(main_df):
    """生成汇总统计信息"""
    print("📊 生成汇总统计信息...")

    summary_stats = {
        'total_patients': main_df['stay_id'].nunique(),
        'sofa1_sepsis_patients': main_df[main_df['sofa1_sepsis'] == True]['stay_id'].nunique(),
        'sofa2_sepsis_patients': main_df[main_df['sofa2_sepsis'] == True]['stay_id'].nunique(),
        'icu_mortality_rate': main_df['icu_mortality'].mean() * 100,
        'hospital_mortality_rate': main_df['hospital_expire_flag'].mean() * 100,
        'mean_icu_los_hours': main_df['icu_los_hours'].mean(),
        'mean_age': main_df['age'].mean(),
        'male_percentage': (main_df['gender'] == 'M').mean() * 100,
        'sofa1_mean_score': main_df['sofa1_score'].mean(),
        'sofa2_mean_score': main_df['sofa2_score'].mean(),
        'data_completeness_sofa1': (main_df['sofa1_score'].notna().mean() * 100),
        'data_completeness_sofa2': (main_df['sofa2_score'].notna().mean() * 100)
    }

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

    return summary_df

def main():
    """主函数"""
    print("🚀 开始提取SOFA-1 vs SOFA-2分析数据...")
    print(f"📁 输出目录: {OUTPUT_DIR}")

    # 创建输出目录
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 连接数据库
    conn = connect_to_database()
    if not conn:
        return

    try:
        # 提取各种数据集
        main_df = extract_main_dataset(conn)
        sofa1_df = extract_sofa1_sepsis_patients(conn)
        sofa2_df = extract_sofa2_sepsis_patients(conn)
        infection_df = extract_suspicion_infection_data(conn)
        icu_df = extract_icu_basic_info(conn)
        distribution_df = extract_score_distributions(conn)

        # 生成报告
        quality_df = generate_data_quality_report(main_df, sofa1_df, sofa2_df)
        summary_df = generate_summary_statistics(main_df)

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