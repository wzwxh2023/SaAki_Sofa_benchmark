"""
Explore MIMIC-IV Database Structure
====================================

This script explores the complete MIMIC-IV dataset structure including:
- All schemas
- All tables in each schema
- Table row counts
- Table column information
- Sample data from key tables
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from utils.db_helper import query_to_df
import pandas as pd

pd.set_option('display.max_columns', None)
pd.set_option('display.width', None)
pd.set_option('display.max_colwidth', 50)

print("=" * 80)
print("MIMIC-IV DATABASE EXPLORATION")
print("=" * 80)
print()

# ============================================================================
# 1. Discover all schemas
# ============================================================================
print("=" * 80)
print("STEP 1: Discover All Schemas")
print("=" * 80)
print()

schemas_sql = """
SELECT
    table_schema as schema_name,
    COUNT(DISTINCT table_name) as table_count
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
  AND table_type = 'BASE TABLE'
GROUP BY table_schema
ORDER BY table_schema;
"""

schemas_df = query_to_df(schemas_sql, db='mimic')
print("📊 Available Schemas:")
print(schemas_df.to_string(index=False))
print()

# ============================================================================
# 2. List all tables in each schema
# ============================================================================
print("=" * 80)
print("STEP 2: All Tables Across All Schemas")
print("=" * 80)
print()

tables_sql = """
SELECT
    table_schema,
    table_name,
    pg_size_pretty(pg_total_relation_size('"' || table_schema || '"."' || table_name || '"')) as size
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
  AND table_type = 'BASE TABLE'
ORDER BY table_schema, table_name;
"""

tables_df = query_to_df(tables_sql, db='mimic')
print(f"📋 Total Tables Found: {len(tables_df)}")
print()

# Group by schema
for schema in schemas_df['schema_name'].values:
    schema_tables = tables_df[tables_df['table_schema'] == schema]
    print(f"\n--- Schema: {schema} ({len(schema_tables)} tables) ---")
    print(schema_tables[['table_name', 'size']].to_string(index=False))

print()

# ============================================================================
# 3. Get row counts for all tables
# ============================================================================
print("=" * 80)
print("STEP 3: Table Row Counts")
print("=" * 80)
print()

# This query gets approximate row counts quickly
rowcount_sql = """
SELECT
    schemaname as schema_name,
    relname as table_name,
    n_live_tup as approximate_rows
FROM pg_stat_user_tables
ORDER BY schemaname, relname;
"""

rowcount_df = query_to_df(rowcount_sql, db='mimic')
print("📊 Table Row Counts (Approximate):")
print()

for schema in schemas_df['schema_name'].values:
    schema_rows = rowcount_df[rowcount_df['schema_name'] == schema]
    if len(schema_rows) > 0:
        print(f"\n--- Schema: {schema} ---")
        # Sort by row count descending
        schema_rows_sorted = schema_rows.sort_values('approximate_rows', ascending=False)
        print(schema_rows_sorted[['table_name', 'approximate_rows']].to_string(index=False))

print()

# ============================================================================
# 4. Explore key table structures
# ============================================================================
print("=" * 80)
print("STEP 4: Key Table Structures")
print("=" * 80)
print()

# Define key tables to examine based on MIMIC-IV skill knowledge
key_tables = [
    ('mimiciv_hosp', 'patients'),
    ('mimiciv_hosp', 'admissions'),
    ('mimiciv_hosp', 'labevents'),
    ('mimiciv_hosp', 'd_labitems'),
    ('mimiciv_icu', 'icustays'),
    ('mimiciv_icu', 'chartevents'),
    ('mimiciv_icu', 'd_items'),
]

for schema, table in key_tables:
    # Check if table exists
    table_exists = ((tables_df['table_schema'] == schema) &
                    (tables_df['table_name'] == table)).any()

    if not table_exists:
        print(f"⚠️  Table {schema}.{table} not found")
        continue

    print(f"\n--- Table: {schema}.{table} ---")

    # Get column information
    columns_sql = f"""
    SELECT
        column_name,
        data_type,
        character_maximum_length,
        is_nullable
    FROM information_schema.columns
    WHERE table_schema = '{schema}'
      AND table_name = '{table}'
    ORDER BY ordinal_position;
    """

    columns_df = query_to_df(columns_sql, db='mimic')
    print("\n📋 Columns:")
    print(columns_df.to_string(index=False))

    # Get sample data
    sample_sql = f"SELECT * FROM {schema}.{table} LIMIT 3;"
    try:
        sample_df = query_to_df(sample_sql, db='mimic')
        print(f"\n📊 Sample Data (first 3 rows):")
        print(sample_df.to_string(index=False))
    except Exception as e:
        print(f"⚠️  Could not retrieve sample data: {e}")

    print()

# ============================================================================
# 5. Explore relationships between key tables
# ============================================================================
print("=" * 80)
print("STEP 5: Table Relationships")
print("=" * 80)
print()

# Get foreign key constraints
fk_sql = """
SELECT
    tc.table_schema,
    tc.table_name,
    kcu.column_name,
    ccu.table_schema AS foreign_table_schema,
    ccu.table_name AS foreign_table_name,
    ccu.column_name AS foreign_column_name
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage AS ccu
    ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY tc.table_schema, tc.table_name, kcu.column_name;
"""

fk_df = query_to_df(fk_sql, db='mimic')

if len(fk_df) > 0:
    print("🔗 Foreign Key Relationships:")
    print()
    for schema in schemas_df['schema_name'].values:
        schema_fks = fk_df[fk_df['table_schema'] == schema]
        if len(schema_fks) > 0:
            print(f"\n--- Schema: {schema} ---")
            for _, row in schema_fks.iterrows():
                print(f"  {row['table_name']}.{row['column_name']} → "
                      f"{row['foreign_table_schema']}.{row['foreign_table_name']}.{row['foreign_column_name']}")
else:
    print("ℹ️  No explicit foreign key constraints found (common in MIMIC-IV)")
    print("   Relationships are documented but not enforced at database level")

print()

# ============================================================================
# 6. Summary Statistics
# ============================================================================
print("=" * 80)
print("STEP 6: Dataset Summary")
print("=" * 80)
print()

total_schemas = len(schemas_df)
total_tables = len(tables_df)
total_rows = rowcount_df['approximate_rows'].sum()

print(f"📊 MIMIC-IV Dataset Summary:")
print(f"   Total Schemas: {total_schemas}")
print(f"   Total Tables: {total_tables}")
print(f"   Total Approximate Rows: {total_rows:,}")
print()

# Largest tables
print("📈 Top 10 Largest Tables by Row Count:")
top_tables = rowcount_df.nlargest(10, 'approximate_rows')
for _, row in top_tables.iterrows():
    print(f"   {row['schema_name']}.{row['table_name']}: {row['approximate_rows']:,} rows")

print()
print("=" * 80)
print("✅ EXPLORATION COMPLETE")
print("=" * 80)
print()
print("💡 Next Steps:")
print("   1. Review the schema structure above")
print("   2. Identify tables relevant to your research")
print("   3. Use the MIMIC-IV skill for query patterns")
print("   4. Start extracting data for SOFA/Sepsis/AKI analysis")
print()
