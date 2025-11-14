#!/usr/bin/env python3
"""
Create SOFA-2 Derived Tables in MIMIC-IV

This script executes the SOFA-2 SQL files and creates derived tables:
1. mimiciv_derived.sofa2 - Hourly SOFA-2 scores
2. mimiciv_derived.first_day_sofa2 - First 24h SOFA-2 scores
3. mimiciv_derived.sepsis3_sofa2 - Sepsis-3 identification using SOFA-2

Usage:
    conda activate rna-seq
    python scripts/create_sofa2_tables.py
"""

import sys
import os
from pathlib import Path
import time
from datetime import datetime

# Add project root to path
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from utils.db_helper import query_to_df, DB_CONFIG
import psycopg2
from psycopg2 import sql


def get_connection(db='mimic'):
    """Get database connection"""
    config = DB_CONFIG[db]
    return psycopg2.connect(
        host=config['host'],
        port=config['port'],
        database=config['database'],
        user=config['user'],
        password=config['password']
    )


def print_header(text):
    """Print formatted header"""
    print("\n" + "=" * 70)
    print(f"  {text}")
    print("=" * 70)


def print_step(step_num, total_steps, text):
    """Print step progress"""
    print(f"\n[{step_num}/{total_steps}] {text}")
    print("-" * 70)


def read_sql_file(filepath):
    """Read SQL file content"""
    with open(filepath, 'r', encoding='utf-8') as f:
        return f.read()


def execute_sql(conn, query, description):
    """Execute SQL query with error handling"""
    cursor = conn.cursor()
    try:
        print(f"⏳ Executing: {description}...")
        start_time = time.time()

        cursor.execute(query)
        conn.commit()

        elapsed = time.time() - start_time
        print(f"✅ Success! (Elapsed: {elapsed:.1f}s)")
        return True
    except psycopg2.Error as e:
        conn.rollback()
        print(f"❌ Error: {e}")
        return False
    finally:
        cursor.close()


def check_table_exists(conn, schema, table_name):
    """Check if table exists"""
    cursor = conn.cursor()
    cursor.execute("""
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_schema = %s
            AND table_name = %s
        );
    """, (schema, table_name))
    exists = cursor.fetchone()[0]
    cursor.close()
    return exists


def get_table_stats(conn, schema, table_name):
    """Get table row count and basic stats"""
    cursor = conn.cursor()
    try:
        cursor.execute(f"""
            SELECT
                COUNT(*) as row_count,
                COUNT(DISTINCT stay_id) as unique_stays
            FROM {schema}.{table_name}
        """)
        result = cursor.fetchone()
        return {'row_count': result[0], 'unique_stays': result[1]}
    except:
        cursor.execute(f"SELECT COUNT(*) FROM {schema}.{table_name}")
        result = cursor.fetchone()
        return {'row_count': result[0], 'unique_stays': None}
    finally:
        cursor.close()


def drop_table_if_exists(conn, schema, table_name):
    """Drop table if it exists"""
    cursor = conn.cursor()
    try:
        cursor.execute(f"DROP TABLE IF EXISTS {schema}.{table_name} CASCADE")
        conn.commit()
        print(f"🗑️  Dropped existing table {schema}.{table_name}")
    except psycopg2.Error as e:
        conn.rollback()
        print(f"⚠️  Warning: Could not drop table: {e}")
    finally:
        cursor.close()


def main():
    """Main execution function"""
    print_header("SOFA-2 Tables Creation for MIMIC-IV")
    print(f"Start Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    # SQL files to execute
    sql_files = [
        {
            'name': 'sofa2',
            'file': project_root / 'sofa2_sql' / 'sofa2.sql',
            'table': 'mimiciv_derived.sofa2',
            'description': 'Hourly SOFA-2 scores for all ICU stays',
            'step': 1
        },
        {
            'name': 'first_day_sofa2',
            'file': project_root / 'sofa2_sql' / 'first_day_sofa2.sql',
            'table': 'mimiciv_derived.first_day_sofa2',
            'description': 'First 24-hour SOFA-2 scores',
            'step': 2
        },
        {
            'name': 'sepsis3_sofa2',
            'file': project_root / 'sofa2_sql' / 'sepsis3_sofa2.sql',
            'table': 'mimiciv_derived.sepsis3_sofa2',
            'description': 'Sepsis-3 identification using SOFA-2',
            'step': 3
        }
    ]

    total_steps = len(sql_files) + 1  # +1 for validation

    # Connect to database
    print_step(0, total_steps, "Connecting to MIMIC-IV database")
    try:
        conn = get_connection('mimic')
        print("✅ Connected to mimiciv database")
    except Exception as e:
        print(f"❌ Failed to connect: {e}")
        return

    # Track success/failure
    results = []

    # Execute each SQL file
    for sql_config in sql_files:
        print_step(sql_config['step'], total_steps,
                   f"Creating {sql_config['table']}")

        print(f"📄 Description: {sql_config['description']}")
        print(f"📁 SQL File: {sql_config['file']}")

        # Check if file exists
        if not sql_config['file'].exists():
            print(f"❌ SQL file not found: {sql_config['file']}")
            results.append({'table': sql_config['table'], 'success': False,
                          'error': 'File not found'})
            continue

        # Read SQL content
        try:
            sql_content = read_sql_file(sql_config['file'])
            print(f"📖 Read SQL file ({len(sql_content)} characters)")
        except Exception as e:
            print(f"❌ Failed to read SQL file: {e}")
            results.append({'table': sql_config['table'], 'success': False,
                          'error': str(e)})
            continue

        # Drop existing table if it exists
        schema, table_name = sql_config['table'].split('.')
        if check_table_exists(conn, schema, table_name):
            print(f"⚠️  Table {sql_config['table']} already exists")
            drop_table_if_exists(conn, schema, table_name)

        # Create table by wrapping query in CREATE TABLE
        create_query = f"""
        CREATE TABLE {sql_config['table']} AS
        {sql_content}
        """

        # Execute
        success = execute_sql(conn, create_query,
                            f"Creating {sql_config['table']}")

        if success:
            # Get table stats
            try:
                stats = get_table_stats(conn, schema, table_name)
                print(f"📊 Table created with {stats['row_count']:,} rows", end="")
                if stats['unique_stays']:
                    print(f" ({stats['unique_stays']:,} unique ICU stays)")
                else:
                    print()

                results.append({
                    'table': sql_config['table'],
                    'success': True,
                    'rows': stats['row_count'],
                    'stays': stats['unique_stays']
                })
            except Exception as e:
                print(f"⚠️  Table created but couldn't get stats: {e}")
                results.append({
                    'table': sql_config['table'],
                    'success': True,
                    'rows': None
                })
        else:
            results.append({
                'table': sql_config['table'],
                'success': False,
                'error': 'Execution failed'
            })

    # Validation step
    print_step(total_steps, total_steps, "Validation and Summary")

    print("\n📋 Summary of Created Tables:")
    print("-" * 70)

    for result in results:
        status = "✅" if result['success'] else "❌"
        print(f"{status} {result['table']}")
        if result['success'] and result.get('rows'):
            print(f"   └─ {result['rows']:,} rows", end="")
            if result.get('stays'):
                print(f", {result['stays']:,} unique ICU stays")
            else:
                print()

    # Final validation query
    if all(r['success'] for r in results):
        print("\n🔍 Running quick validation query...")
        try:
            validation_query = """
            SELECT
                'sofa2' as table_name,
                COUNT(*) as row_count,
                COUNT(DISTINCT stay_id) as unique_stays,
                ROUND(AVG(sofa2_24hours), 2) as avg_sofa2
            FROM mimiciv_derived.sofa2
            WHERE hr = 24  -- First complete 24h

            UNION ALL

            SELECT
                'first_day_sofa2' as table_name,
                COUNT(*) as row_count,
                COUNT(DISTINCT stay_id) as unique_stays,
                ROUND(AVG(sofa2_total), 2) as avg_sofa2
            FROM mimiciv_derived.first_day_sofa2

            UNION ALL

            SELECT
                'sepsis3_sofa2' as table_name,
                COUNT(*) as row_count,
                COUNT(DISTINCT stay_id) as unique_stays,
                ROUND(AVG(sofa2_score), 2) as avg_sofa2
            FROM mimiciv_derived.sepsis3_sofa2
            """

            df = query_to_df(validation_query, db='mimic')
            print("\n📊 Validation Results:")
            print(df.to_string(index=False))

            # Check cardiovascular 2-point prevalence (KEY METRIC)
            print("\n🎯 Key Validation Metric: Cardiovascular 2-point prevalence")
            cv_query = """
            SELECT
                ROUND(100.0 * COUNT(*) FILTER (WHERE cardiovascular_24hours = 2) /
                      NULLIF(COUNT(*), 0), 2) as cv_2point_pct
            FROM mimiciv_derived.first_day_sofa2
            WHERE cardiovascular_24hours IS NOT NULL
            """
            cv_result = query_to_df(cv_query, db='mimic')
            cv_pct = cv_result['cv_2point_pct'].iloc[0]

            print(f"   Cardiovascular 2-point: {cv_pct}%")
            if 7.0 <= cv_pct <= 11.0:
                print(f"   ✅ Within expected range (8-9% per JAMA 2025)")
            else:
                print(f"   ⚠️  Outside expected range (expected ~8.9%)")
                print(f"   This may need investigation.")

        except Exception as e:
            print(f"⚠️  Validation query failed: {e}")

    # Close connection
    conn.close()

    # Final summary
    print_header("Execution Complete")
    success_count = sum(1 for r in results if r['success'])
    print(f"✅ Successfully created: {success_count}/{len(results)} tables")

    if success_count == len(results):
        print("\n🎉 All SOFA-2 tables created successfully!")
        print("\nNext steps:")
        print("1. Run validation: psql -f sofa2_sql/validation/compare_sofa1_sofa2.sql")
        print("2. Build SA-AKI cohort for your Letter research")
        print("3. Calculate AUC and compare SOFA-1 vs SOFA-2")
    else:
        print("\n⚠️  Some tables failed to create. Please check errors above.")

    print(f"\nEnd Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")


if __name__ == "__main__":
    main()
