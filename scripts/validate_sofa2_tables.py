#!/usr/bin/env python3
"""
Validate SOFA-2 tables after creation
"""

import sys
from pathlib import Path
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from utils.db_helper import DB_CONFIG
import psycopg2

def get_connection():
    config = DB_CONFIG['mimic']
    return psycopg2.connect(
        host=config['host'],
        port=config['port'],
        database=config['database'],
        user=config['user'],
        password=config['password']
    )

def check_table(cursor, table_name):
    """Check if table exists and get statistics"""
    try:
        # Check if table exists
        cursor.execute(f"""
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = 'mimiciv_derived'
            AND table_name = '{table_name.split('.')[1]}'
        """)
        exists = cursor.fetchone()[0] > 0

        if not exists:
            return {'exists': False}

        # Get row count
        cursor.execute(f"SELECT COUNT(*) FROM {table_name}")
        row_count = cursor.fetchone()[0]

        # Get unique stay_ids
        cursor.execute(f"SELECT COUNT(DISTINCT stay_id) FROM {table_name}")
        unique_stays = cursor.fetchone()[0]

        # Get sample of columns
        cursor.execute(f"""
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'mimiciv_derived'
            AND table_name = '{table_name.split('.')[1]}'
            ORDER BY ordinal_position
        """)
        columns = [row[0] for row in cursor.fetchall()]

        return {
            'exists': True,
            'row_count': row_count,
            'unique_stays': unique_stays,
            'columns': columns
        }
    except Exception as e:
        return {'exists': False, 'error': str(e)}

def main():
    print("="*70)
    print("  SOFA-2 Tables Validation")
    print("="*70)

    tables = [
        ('mimiciv_derived.sofa2', 'Hourly SOFA-2 scores'),
        ('mimiciv_derived.first_day_sofa2', 'First 24h SOFA-2 scores'),
        ('mimiciv_derived.sepsis3_sofa2', 'Sepsis-3 using SOFA-2')
    ]

    conn = get_connection()
    cursor = conn.cursor()

    results = {}
    for table_name, description in tables:
        print(f"\n{'='*70}")
        print(f"  {table_name}")
        print(f"  {description}")
        print(f"{'='*70}")

        info = check_table(cursor, table_name)
        results[table_name] = info

        if info['exists']:
            print(f"✅ Table exists")
            print(f"📊 Total rows: {info['row_count']:,}")
            print(f"👥 Unique ICU stays: {info['unique_stays']:,}")
            print(f"📋 Columns ({len(info['columns'])}): {', '.join(info['columns'][:5])}...")
        else:
            print(f"❌ Table does not exist")
            if 'error' in info:
                print(f"   Error: {info['error']}")

    cursor.close()
    conn.close()

    # Summary
    print(f"\n{'='*70}")
    print("  Summary")
    print(f"{'='*70}")

    all_exist = all(results[t[0]]['exists'] for t in tables)

    for table_name, description in tables:
        status = '✅' if results[table_name]['exists'] else '❌'
        print(f"{status} {table_name}")
        if results[table_name]['exists']:
            info = results[table_name]
            print(f"   └─ {info['row_count']:,} rows, {info['unique_stays']:,} ICU stays")

    print(f"{'='*70}")

    if all_exist:
        print("✅ All SOFA-2 tables created successfully!")
    else:
        print("⚠️  Some tables are missing. Please check errors above.")

    print(f"{'='*70}")

    return all_exist

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)
