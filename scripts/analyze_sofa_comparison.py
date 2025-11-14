#!/usr/bin/env python3
"""
Comprehensive SOFA-1 vs SOFA-2 Comparison Analysis
"""

import sys
from pathlib import Path
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))

from utils.db_helper import DB_CONFIG
import psycopg2
import pandas as pd
import numpy as np
from scipy import stats
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

def create_comparison_table(conn, sql_file, table_name):
    """Create comparison table from SQL file"""
    print(f"\n{'='*70}")
    print(f"  Creating {table_name}")
    print(f"{'='*70}")

    with open(sql_file, 'r', encoding='utf-8') as f:
        sql_content = f.read()

    print(f"📖 Read SQL file ({len(sql_content)} characters)")

    cursor = conn.cursor()
    try:
        # Drop if exists
        cursor.execute(f"DROP TABLE IF EXISTS {table_name} CASCADE")
        conn.commit()

        # Create table
        print("⏳ Creating comparison table...")
        start_time = time.time()

        create_query = f"CREATE TABLE {table_name} AS {sql_content}"
        cursor.execute(create_query)
        conn.commit()

        elapsed = time.time() - start_time

        # Get row count
        cursor.execute(f"SELECT COUNT(*) FROM {table_name}")
        row_count = cursor.fetchone()[0]

        print(f"✅ Success! (Elapsed: {elapsed:.1f}s)")
        print(f"📊 Table created with {row_count:,} rows")

        return True

    except Exception as e:
        conn.rollback()
        print(f"❌ Error: {e}")
        return False
    finally:
        cursor.close()

def load_comparison_data(conn, table_name):
    """Load comparison data into pandas DataFrame"""
    print(f"\n📥 Loading data from {table_name}...")
    query = f"SELECT * FROM {table_name}"
    df = pd.read_sql_query(query, conn)
    print(f"✅ Loaded {len(df):,} rows")
    return df

def calculate_distribution_stats(df, score_cols, label):
    """Calculate distribution statistics for scores"""
    print(f"\n{'='*70}")
    print(f"  {label} - Distribution Statistics")
    print(f"{'='*70}")

    stats_list = []
    for col in score_cols:
        if col not in df.columns:
            continue

        data = df[col].dropna()

        stats_dict = {
            'Component': col.replace(label.lower() + '_', '').replace('_', ' ').title(),
            'N': len(data),
            'Mean': data.mean(),
            'Std': data.std(),
            'Median': data.median(),
            'IQR_25': data.quantile(0.25),
            'IQR_75': data.quantile(0.75),
            'Min': data.min(),
            'Max': data.max(),
            'Score_0': (data == 0).sum(),
            'Score_1': (data == 1).sum(),
            'Score_2': (data == 2).sum(),
            'Score_3': (data == 3).sum(),
            'Score_4': (data == 4).sum(),
        }
        stats_list.append(stats_dict)

    stats_df = pd.DataFrame(stats_list)
    return stats_df

def calculate_correlations(df, sofa1_cols, sofa2_cols):
    """Calculate correlations between SOFA-1 and SOFA-2 scores"""
    print(f"\n{'='*70}")
    print(f"  SOFA-1 vs SOFA-2 Correlations")
    print(f"{'='*70}")

    corr_list = []

    for s1_col, s2_col in zip(sofa1_cols, sofa2_cols):
        if s1_col not in df.columns or s2_col not in df.columns:
            continue

        # Remove rows with missing values
        valid_data = df[[s1_col, s2_col]].dropna()

        if len(valid_data) < 2:
            continue

        # Pearson correlation
        pearson_r, pearson_p = stats.pearsonr(valid_data[s1_col], valid_data[s2_col])

        # Spearman correlation
        spearman_r, spearman_p = stats.spearmanr(valid_data[s1_col], valid_data[s2_col])

        # Calculate agreement (exact match)
        agreement = (valid_data[s1_col] == valid_data[s2_col]).mean()

        # Mean absolute difference
        mad = (valid_data[s2_col] - valid_data[s1_col]).abs().mean()

        component = s1_col.replace('sofa1_', '').replace('_', ' ').title()

        corr_list.append({
            'Component': component,
            'N': len(valid_data),
            'Pearson_r': pearson_r,
            'Pearson_p': pearson_p,
            'Spearman_r': spearman_r,
            'Spearman_p': spearman_p,
            'Exact_Agreement': agreement,
            'Mean_Abs_Diff': mad
        })

    corr_df = pd.DataFrame(corr_list)
    return corr_df

def analyze_score_differences(df):
    """Analyze differences between SOFA-1 and SOFA-2"""
    print(f"\n{'='*70}")
    print(f"  Score Differences (SOFA-2 - SOFA-1)")
    print(f"{'='*70}")

    diff_cols = [col for col in df.columns if col.endswith('_diff')]

    diff_stats = []
    for col in diff_cols:
        data = df[col].dropna()

        component = col.replace('_diff', '').replace('_', ' ').title()

        diff_stats.append({
            'Component': component,
            'Mean_Diff': data.mean(),
            'Median_Diff': data.median(),
            'Std_Diff': data.std(),
            'SOFA2_Higher': (data > 0).sum(),
            'No_Change': (data == 0).sum(),
            'SOFA1_Higher': (data < 0).sum(),
            'Max_Increase': data.max(),
            'Max_Decrease': data.min()
        })

    diff_df = pd.DataFrame(diff_stats)
    return diff_df

def analyze_risk_categorization(df):
    """Analyze SOFA >= 2 categorization agreement"""
    print(f"\n{'='*70}")
    print(f"  High Risk (SOFA >= 2) Categorization")
    print(f"{'='*70}")

    both_high = df['both_high_risk'].sum()
    both_low = df['both_low_risk'].sum()
    sofa1_only = df['sofa1_only_high'].sum()
    sofa2_only = df['sofa2_only_high'].sum()

    total = len(df)
    agreement = (both_high + both_low) / total
    kappa = calculate_cohen_kappa(df['sofa1_high_risk'], df['sofa2_high_risk'])

    print(f"Total ICU Stays: {total:,}")
    print(f"\nCategorization Agreement:")
    print(f"  Both High Risk (≥2):     {both_high:>8,} ({both_high/total*100:>5.1f}%)")
    print(f"  Both Low Risk (<2):      {both_low:>8,} ({both_low/total*100:>5.1f}%)")
    print(f"  SOFA-1 Only High:        {sofa1_only:>8,} ({sofa1_only/total*100:>5.1f}%)")
    print(f"  SOFA-2 Only High:        {sofa2_only:>8,} ({sofa2_only/total*100:>5.1f}%)")
    print(f"\n  Overall Agreement:       {agreement*100:.1f}%")
    print(f"  Cohen's Kappa:           {kappa:.3f}")

    return {
        'total': total,
        'both_high': both_high,
        'both_low': both_low,
        'sofa1_only': sofa1_only,
        'sofa2_only': sofa2_only,
        'agreement': agreement,
        'kappa': kappa
    }

def calculate_cohen_kappa(y1, y2):
    """Calculate Cohen's Kappa for agreement"""
    # Create confusion matrix
    both_yes = ((y1 == 1) & (y2 == 1)).sum()
    both_no = ((y1 == 0) & (y2 == 0)).sum()
    y1_yes_y2_no = ((y1 == 1) & (y2 == 0)).sum()
    y1_no_y2_yes = ((y1 == 0) & (y2 == 1)).sum()

    n = len(y1)
    po = (both_yes + both_no) / n  # Observed agreement

    # Expected agreement
    p_y1_yes = (both_yes + y1_yes_y2_no) / n
    p_y2_yes = (both_yes + y1_no_y2_yes) / n
    p_y1_no = 1 - p_y1_yes
    p_y2_no = 1 - p_y2_yes
    pe = p_y1_yes * p_y2_yes + p_y1_no * p_y2_no

    kappa = (po - pe) / (1 - pe) if pe != 1 else 1.0
    return kappa

def analyze_sepsis_comparison(df):
    """Analyze sepsis identification comparison"""
    print(f"\n{'='*70}")
    print(f"  Sepsis-3 Identification Comparison")
    print(f"{'='*70}")

    # Count by agreement category
    category_counts = df['agreement_category'].value_counts()
    total = len(df)

    print(f"Total ICU Stays: {total:,}\n")

    for category, count in category_counts.items():
        pct = count / total * 100
        print(f"  {category:<20} {count:>8,} ({pct:>5.1f}%)")

    # Calculate agreement metrics
    both_sepsis = (df['agreement_category'] == 'Both_Sepsis').sum()
    neither_sepsis = (df['agreement_category'] == 'Neither_Sepsis').sum()
    sofa1_only = (df['agreement_category'] == 'SOFA1_Only').sum()
    sofa2_only = (df['agreement_category'] == 'SOFA2_Only').sum()

    agreement = (both_sepsis + neither_sepsis) / total
    kappa = calculate_cohen_kappa(df['sepsis1'], df['sepsis2'])

    print(f"\n  Overall Agreement:       {agreement*100:.1f}%")
    print(f"  Cohen's Kappa:           {kappa:.3f}")

    # Sepsis prevalence
    sepsis1_prev = df['sepsis1'].sum() / total * 100
    sepsis2_prev = df['sepsis2'].sum() / total * 100

    print(f"\nSepsis Prevalence:")
    print(f"  SOFA-1 based:            {df['sepsis1'].sum():>8,} ({sepsis1_prev:>5.1f}%)")
    print(f"  SOFA-2 based:            {df['sepsis2'].sum():>8,} ({sepsis2_prev:>5.1f}%)")
    print(f"  Difference:              {df['sepsis2'].sum() - df['sepsis1'].sum():>+8,} ({sepsis2_prev - sepsis1_prev:>+5.1f}%)")

    return {
        'total': total,
        'both_sepsis': both_sepsis,
        'neither_sepsis': neither_sepsis,
        'sofa1_only': sofa1_only,
        'sofa2_only': sofa2_only,
        'agreement': agreement,
        'kappa': kappa,
        'sepsis1_count': df['sepsis1'].sum(),
        'sepsis2_count': df['sepsis2'].sum(),
        'sepsis1_prev': sepsis1_prev,
        'sepsis2_prev': sepsis2_prev
    }

def save_results(output_dir, **kwargs):
    """Save all results to CSV files"""
    print(f"\n{'='*70}")
    print(f"  Saving Results")
    print(f"{'='*70}")

    output_dir = Path(output_dir)
    output_dir.mkdir(exist_ok=True)

    for name, df in kwargs.items():
        if isinstance(df, pd.DataFrame):
            filepath = output_dir / f"{name}.csv"
            df.to_csv(filepath, index=False)
            print(f"✅ Saved: {filepath}")

def main():
    print("="*70)
    print("  SOFA-1 vs SOFA-2 Comprehensive Comparison Analysis")
    print("="*70)

    conn = get_connection()

    try:
        # 1. Create comparison tables
        print("\n" + "="*70)
        print("  PART 1: Creating Comparison Tables")
        print("="*70)

        sofa_comparison_sql = project_root / 'sofa2_sql' / 'validation' / 'sofa1_vs_sofa2_comparison.sql'
        sepsis_comparison_sql = project_root / 'sofa2_sql' / 'validation' / 'sepsis_comparison.sql'

        create_comparison_table(conn, sofa_comparison_sql, 'mimiciv_derived.sofa_comparison')
        create_comparison_table(conn, sepsis_comparison_sql, 'mimiciv_derived.sepsis_comparison')

        # 2. Load data
        print("\n" + "="*70)
        print("  PART 2: Loading Data")
        print("="*70)

        sofa_df = load_comparison_data(conn, 'mimiciv_derived.sofa_comparison')
        sepsis_df = load_comparison_data(conn, 'mimiciv_derived.sepsis_comparison')

        # 3. Distribution analysis
        print("\n" + "="*70)
        print("  PART 3: Distribution Analysis")
        print("="*70)

        sofa1_cols = ['sofa1_total', 'sofa1_brain', 'sofa1_respiratory',
                      'sofa1_cardiovascular', 'sofa1_liver', 'sofa1_kidney', 'sofa1_hemostasis']
        sofa2_cols = ['sofa2_total', 'sofa2_brain', 'sofa2_respiratory',
                      'sofa2_cardiovascular', 'sofa2_liver', 'sofa2_kidney', 'sofa2_hemostasis']

        sofa1_stats = calculate_distribution_stats(sofa_df, sofa1_cols, 'SOFA1')
        print("\n" + sofa1_stats.to_string(index=False))

        sofa2_stats = calculate_distribution_stats(sofa_df, sofa2_cols, 'SOFA2')
        print("\n" + sofa2_stats.to_string(index=False))

        # 4. Correlation analysis
        print("\n" + "="*70)
        print("  PART 4: Correlation Analysis")
        print("="*70)

        corr_df = calculate_correlations(sofa_df, sofa1_cols, sofa2_cols)
        print("\n" + corr_df.to_string(index=False))

        # 5. Difference analysis
        print("\n" + "="*70)
        print("  PART 5: Score Difference Analysis")
        print("="*70)

        diff_df = analyze_score_differences(sofa_df)
        print("\n" + diff_df.to_string(index=False))

        # 6. Risk categorization analysis
        print("\n" + "="*70)
        print("  PART 6: Risk Categorization Analysis")
        print("="*70)

        risk_stats = analyze_risk_categorization(sofa_df)

        # 7. Sepsis comparison analysis
        print("\n" + "="*70)
        print("  PART 7: Sepsis Identification Analysis")
        print("="*70)

        sepsis_stats = analyze_sepsis_comparison(sepsis_df)

        # 8. Save results
        output_dir = project_root / 'results' / 'sofa_comparison'
        save_results(
            output_dir,
            sofa1_distribution=sofa1_stats,
            sofa2_distribution=sofa2_stats,
            correlations=corr_df,
            score_differences=diff_df,
            sofa_comparison_data=sofa_df,
            sepsis_comparison_data=sepsis_df
        )

        print("\n" + "="*70)
        print("  Analysis Complete!")
        print("="*70)
        print(f"Results saved to: {output_dir}")

    finally:
        conn.close()

if __name__ == "__main__":
    main()
