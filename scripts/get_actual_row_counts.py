"""
Get Actual Row Counts for Key MIMIC-IV Tables
==============================================
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from utils.db_helper import query_to_df
import pandas as pd

print("=" * 80)
print("MIMIC-IV ACTUAL ROW COUNTS")
print("=" * 80)
print()

# Key tables to count
key_tables = {
    'Core Tables': [
        ('mimiciv_hosp', 'patients'),
        ('mimiciv_hosp', 'admissions'),
        ('mimiciv_icu', 'icustays'),
    ],
    'Hospital Data': [
        ('mimiciv_hosp', 'labevents'),
        ('mimiciv_hosp', 'prescriptions'),
        ('mimiciv_hosp', 'diagnoses_icd'),
        ('mimiciv_hosp', 'microbiologyevents'),
        ('mimiciv_hosp', 'd_labitems'),
    ],
    'ICU Data': [
        ('mimiciv_icu', 'chartevents'),
        ('mimiciv_icu', 'inputevents'),
        ('mimiciv_icu', 'outputevents'),
        ('mimiciv_icu', 'd_items'),
    ],
    'Derived/Concepts': [
        ('mimiciv_derived', 'sofa'),
        ('mimiciv_derived', 'sepsis3'),
        ('mimiciv_derived', 'kdigo_stages'),
        ('mimiciv_derived', 'first_day_sofa'),
        ('mimiciv_derived', 'first_day_lab'),
    ]
}

results = []

for category, tables in key_tables.items():
    print(f"\n{category}:")
    print("-" * 60)

    for schema, table in tables:
        try:
            sql = f"SELECT COUNT(*) as count FROM {schema}.{table};"
            df = query_to_df(sql, db='mimic')
            count = df.iloc[0]['count']
            results.append({
                'Category': category,
                'Schema': schema,
                'Table': table,
                'Row Count': f"{count:,}"
            })
            print(f"  {schema}.{table:30s}: {count:,}")
        except Exception as e:
            print(f"  {schema}.{table:30s}: ERROR - {e}")
            results.append({
                'Category': category,
                'Schema': schema,
                'Table': table,
                'Row Count': 'ERROR'
            })

print()
print("=" * 80)
print("SUMMARY")
print("=" * 80)
print()

results_df = pd.DataFrame(results)
print(results_df.to_string(index=False))
print()
