"""
示例：Claude Code如何帮您快速查询数据
（不需要打开Navicat，不需要手动写SQL）
"""

import sys
sys.path.append('/mnt/f/SaAki_Sofa_benchmark')

from utils.db_helper import query_to_df, show_sample_data, export_to_csv

# =============================================================================
# 示例1：快速查询SA-AKI患者（Claude自动生成SQL）
# =============================================================================

print("示例1：查询SA-AKI患者基本信息")
print("="*60)

sql_sa_aki_patients = """
SELECT
    i.subject_id,
    i.hadm_id,
    i.stay_id,
    i.intime,
    i.outtime,
    i.los,
    p.anchor_age as age,
    p.gender
FROM mimiciv_icu.icustays i
INNER JOIN mimiciv_hosp.patients p
    ON i.subject_id = p.subject_id
WHERE i.stay_id IN (
    SELECT DISTINCT stay_id
    FROM mimiciv_derived.sepsis3
)
LIMIT 100;
"""

# 执行查询（Claude会自动执行）
df_patients = query_to_df(sql_sa_aki_patients, db='mimic')

# 显示结果（类似Navicat的结果窗口）
print("\n前5行数据:")
print(df_patients.head())

print(f"\n✅ 查询到 {len(df_patients)} 名SA-AKI患者")
print(f"📊 数据维度: {df_patients.shape}")
print(f"📋 列名: {', '.join(df_patients.columns.tolist())}")


# =============================================================================
# 示例2：快速统计分析（不需要导出CSV）
# =============================================================================

print("\n" + "="*60)
print("示例2：快速统计分析")
print("="*60)

print(f"\n年龄分布:")
print(df_patients['age'].describe())

print(f"\n性别分布:")
print(df_patients['gender'].value_counts())

print(f"\nICU住院时间分布:")
print(df_patients['los'].describe())


# =============================================================================
# 示例3：如果需要导出（一行代码）
# =============================================================================

print("\n" + "="*60)
print("示例3：导出到CSV")
print("="*60)

# Claude会自动执行导出
export_to_csv(
    sql_sa_aki_patients,
    output_file='/mnt/f/SaAki_Sofa_benchmark/data/sa_aki_patients_sample.csv',
    db='mimic'
)

print("\n✅ 完成！从查询到分析到导出，一气呵成！")
