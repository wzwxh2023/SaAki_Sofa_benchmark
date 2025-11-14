#!/usr/bin/env python3
"""
Create sepsis3_sofa2 table (after fixing PostgreSQL syntax)
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

def main():
    print("="*70)
    print("  Creating mimiciv_derived.sepsis3_sofa2")
    print("="*70)

    # Read SQL
    sql_file = project_root / 'sofa2_sql' / 'sepsis3_sofa2.sql'
    with open(sql_file, 'r', encoding='utf-8') as f:
        sql_content = f.read()

    print(f"📖 Read SQL file ({len(sql_content)} characters)")

    # Connect and execute
    conn = get_connection()
    cursor = conn.cursor()

    try:
        # Drop if exists
        cursor.execute("DROP TABLE IF EXISTS mimiciv_derived.sepsis3_sofa2 CASCADE")
        conn.commit()
        print("🗑️  Dropped existing table if any")

        # Create table
        print("⏳ Executing CREATE TABLE...")
        start_time = time.time()

        create_query = f"CREATE TABLE mimiciv_derived.sepsis3_sofa2 AS {sql_content}"
        cursor.execute(create_query)
        conn.commit()

        elapsed = time.time() - start_time
        print(f"✅ Success! (Elapsed: {elapsed:.1f}s)")

        # Get row count
        cursor.execute("SELECT COUNT(*) FROM mimiciv_derived.sepsis3_sofa2")
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

if __name__ == "__main__":
    success = main()
    print("="*70)
    if success:
        print("✅ sepsis3_sofa2 table created successfully!")
    else:
        print("❌ Failed to create sepsis3_sofa2 table")
    print("="*70)
