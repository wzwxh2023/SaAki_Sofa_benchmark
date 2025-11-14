#!/usr/bin/env python3
"""
Create remaining SOFA-2 tables (sofa2 and sepsis3_sofa2)
"""

import sys
from pathlib import Path
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from utils.db_helper import DB_CONFIG
import psycopg2
import time

def get_connection():
    config = DB_CONFIG['mimic']
    return psycopg2.connect(
        host=config['host'],
        port=config['port'],
        database=config['database'],
        user=config['user'],
        password=config['password']
    )

def execute_sql_file(filepath, table_name):
    """Execute SQL file to create table"""
    print(f"\n{'='*70}")
    print(f"  Creating {table_name}")
    print(f"{'='*70}")

    # Read SQL
    with open(filepath, 'r', encoding='utf-8') as f:
        sql_content = f.read()

    print(f"📖 Read SQL file ({len(sql_content)} characters)")

    # Connect and execute
    conn = get_connection()
    cursor = conn.cursor()

    try:
        # Drop if exists
        cursor.execute(f"DROP TABLE IF EXISTS {table_name} CASCADE")
        conn.commit()
        print(f"🗑️  Dropped existing table if any")

        # Create table
        print(f"⏳ Executing CREATE TABLE...")
        start_time = time.time()

        create_query = f"CREATE TABLE {table_name} AS {sql_content}"
        cursor.execute(create_query)
        conn.commit()

        elapsed = time.time() - start_time
        print(f"✅ Success! (Elapsed: {elapsed:.1f}s)")

        # Get row count
        cursor.execute(f"SELECT COUNT(*) FROM {table_name}")
        row_count = cursor.fetchone()[0]
        print(f"📊 Table created with {row_count:,} rows")

        return True

    except Exception as e:
        conn.rollback()
        print(f"❌ Error: {e}")
        return False

    finally:
        cursor.close()
        conn.close()

def main():
    print("="*70)
    print("  Creating Remaining SOFA-2 Tables")
    print("="*70)

    # Create sofa2 table
    sofa2_success = execute_sql_file(
        project_root / 'sofa2_sql' / 'sofa2.sql',
        'mimiciv_derived.sofa2'
    )

    # Create sepsis3_sofa2 table (only if sofa2 succeeded)
    if sofa2_success:
        sepsis3_success = execute_sql_file(
            project_root / 'sofa2_sql' / 'sepsis3_sofa2.sql',
            'mimiciv_derived.sepsis3_sofa2'
        )
    else:
        sepsis3_success = False
        print("\n⚠️  Skipping sepsis3_sofa2 creation (sofa2 failed)")

    # Summary
    print("\n" + "="*70)
    print("  Summary")
    print("="*70)
    print(f"sofa2:          {'✅' if sofa2_success else '❌'}")
    print(f"sepsis3_sofa2:  {'✅' if sepsis3_success else '❌'}")
    print("="*70)

if __name__ == "__main__":
    main()
