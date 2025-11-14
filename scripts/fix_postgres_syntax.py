#!/usr/bin/env python3
"""
Fix PostgreSQL syntax in SOFA-2 SQL files

Converts BigQuery syntax to PostgreSQL syntax:
- DATETIME_SUB(date, INTERVAL 'X' UNIT) -> date - INTERVAL 'X UNIT'
- DATETIME_ADD(date, INTERVAL 'X' UNIT) -> date + INTERVAL 'X UNIT'
- pr.startdate -> pr.starttime
- pr.stopdate -> pr.stoptime
- DATETIME_TRUNC -> DATE_TRUNC
"""

import re
from pathlib import Path

project_root = Path(__file__).parent.parent
sql_dir = project_root / 'sofa2_sql'

def fix_datetime_sub(content):
    """Convert DATETIME_SUB to PostgreSQL syntax"""
    # Pattern: DATETIME_SUB(expr, INTERVAL 'X' UNIT)
    # Replace with: expr - INTERVAL 'X UNIT'
    pattern = r"DATETIME_SUB\(([^,]+),\s*INTERVAL\s+'(\d+)'\s+(\w+)\)"
    replacement = r"\1 - INTERVAL '\2 \3'"
    return re.sub(pattern, replacement, content, flags=re.IGNORECASE)

def fix_datetime_add(content):
    """Convert DATETIME_ADD to PostgreSQL syntax"""
    # Pattern: DATETIME_ADD(expr, INTERVAL 'X' UNIT)
    # Replace with: expr + INTERVAL 'X UNIT'
    pattern = r"DATETIME_ADD\(([^,]+),\s*INTERVAL\s+'(\d+)'\s+(\w+)\)"
    replacement = r"\1 + INTERVAL '\2 \3'"
    return re.sub(pattern, replacement, content, flags=re.IGNORECASE)

def fix_prescription_fields(content):
    """Fix prescription table field names"""
    content = content.replace('pr.startdate', 'pr.starttime::date')
    content = content.replace('pr.stopdate', 'pr.stoptime::date')
    return content

def fix_datetime_trunc(content):
    """Convert DATETIME_TRUNC to DATE_TRUNC"""
    return content.replace('DATETIME_TRUNC', 'DATE_TRUNC')

def fix_cast_date(content):
    """Fix CAST(... AS DATE) to use ::date"""
    pattern = r'CAST\(([^)]+)\s+AS\s+DATE\)'
    replacement = r'(\1)::date'
    return re.sub(pattern, replacement, content, flags=re.IGNORECASE)

def process_sql_file(filepath):
    """Process a single SQL file"""
    print(f"Processing: {filepath.name}")

    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    original_content = content

    # Apply fixes
    content = fix_datetime_sub(content)
    content = fix_datetime_add(content)
    content = fix_prescription_fields(content)
    content = fix_datetime_trunc(content)
    content = fix_cast_date(content)

    if content != original_content:
        # Backup original
        backup_path = filepath.with_suffix('.sql.bak')
        with open(backup_path, 'w', encoding='utf-8') as f:
            f.write(original_content)

        # Write fixed version
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)

        print(f"  ✅ Fixed and backed up to {backup_path.name}")
        return True
    else:
        print(f"  ℹ️  No changes needed")
        return False

def main():
    """Main execution"""
    print("=" * 70)
    print("  PostgreSQL Syntax Fixer for SOFA-2 SQL Files")
    print("=" * 70)

    sql_files = [
        sql_dir / 'sofa2.sql',
        sql_dir / 'first_day_sofa2.sql',
        sql_dir / 'sepsis3_sofa2.sql',
    ]

    fixed_count = 0
    for sql_file in sql_files:
        if sql_file.exists():
            if process_sql_file(sql_file):
                fixed_count += 1
        else:
            print(f"❌ File not found: {sql_file}")

    print("\n" + "=" * 70)
    print(f"  Fixed {fixed_count}/{len(sql_files)} files")
    print("=" * 70)

if __name__ == "__main__":
    main()
