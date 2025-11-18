-- SOFA2输出数据量和空间占用分析
-- 基于MIMIC-IV数据库实际规模估算

-- 1. 基础数据规模查询
SELECT
    'MIMIC-IV Scale Analysis' as analysis_type,
    COUNT(DISTINCT stay_id) as total_icu_stays,
    ROUND(AVG(icu_los_hours), 1) as avg_icu_los_hours,
    ROUND(MAX(icu_los_hours), 1) as max_icu_los_hours,
    ROUND(SUM(icu_los_hours), 0) as total_icu_hours
FROM (
    SELECT
        stay_id,
        EXTRACT(EPOCH FROM (outtime - intime))/3600 as icu_los_hours
    FROM mimiciv_icu.icustays
) icu_stats;

-- 2. 预期SOFA2输出行数估算
SELECT
    'Output Rows Estimation' as analysis_type,
    COUNT(DISTINCT stay_id) as icu_stays,
    ROUND(AVG(icu_los_hours), 1) as avg_hours_per_stay,
    ROUND(COUNT(DISTINCT stay_id) * AVG(icu_los_hours), 0) as estimated_total_rows,
    ROUND(COUNT(DISTINCT stay_id) * AVG(icu_los_hours) * 365.0 / COUNT(DISTINCT stay_id), 1) as avg_rows_per_year
FROM (
    SELECT
        stay_id,
        EXTRACT(EPOCH FROM (outtime - intime))/3600 as icu_los_hours
    FROM mimiciv_icu.icustays
) icu_stats;

-- 3. 单行数据大小估算
SELECT
    'Row Size Analysis' as analysis_type,
    -- 基于字段类型估算单行大小
    8 + -- stay_id (INTEGER)
    8 + -- hadm_id (INTEGER)
    8 + -- subject_id (INTEGER)
    4 + -- hr (INTEGER)
    8 + -- starttime (TIMESTAMP)
    8 + -- endtime (TIMESTAMP)
    4 + -- brain (SMALLINT)
    4 + -- respiratory (SMALLINT)
    4 + -- cardiovascular (SMALLINT)
    4 + -- liver (SMALLINT)
    4 + -- kidney (SMALLINT)
    4 + -- hemostasis (SMALLINT)
    4   -- sofa2_total (SMALLINT)
    as estimated_bytes_per_row,
    -- 加上PostgreSQL行头开销
    23 + -- 行头开销
    (8 + 8 + 8 + 4 + 8 + 8 + 4 + 4 + 4 + 4 + 4 + 4 + 4) as data_bytes,
    (8 + 8 + 8 + 4 + 8 + 8 + 4 + 4 + 4 + 4 + 4 + 4 + 4) + 23 as total_bytes_per_row;

-- 4. 总空间占用估算（不同压缩级别）
WITH row_estimate AS (
    SELECT
        COUNT(DISTINCT stay_id) * AVG(icu_los_hours) as estimated_rows
    FROM (
        SELECT
            stay_id,
            EXTRACT(EPOCH FROM (outtime - intime))/3600 as icu_los_hours
        FROM mimiciv_icu.icustays
    ) icu_stats
)
SELECT
    'Storage Estimation' as analysis_type,
    estimated_rows,
    ROUND(estimated_rows * 80.0, 0) as uncompressed_size_mb,  -- 80字节/行（未压缩）
    ROUND(estimated_rows * 80.0 / 1024.0, 1) as uncompressed_size_gb,
    ROUND(estimated_rows * 80.0 * 0.6 / 1024.0, 1) as compressed_size_gb,  -- 假设60%压缩率
    ROUND(estimated_rows * 80.0 * 0.4 / 1024.0, 1) as highly_compressed_size_gb  -- 假设40%压缩率
FROM row_estimate;

-- 5. 不同输出策略的空间对比
SELECT
    'Output Strategy Comparison' as analysis_type,
    strategy,
    estimated_rows,
    ROUND(row_size_mb, 1) as estimated_size_mb,
    ROUND(row_size_mb / 1024.0, 2) as estimated_size_gb,
    reduction_factor
FROM (
    SELECT
        'Hourly Output (Current)' as strategy,
        COUNT(DISTINCT stay_id) * AVG(icu_los_hours) as estimated_rows,
        COUNT(DISTINCT stay_id) * AVG(icu_los_hours) * 80.0 / 1024.0 / 1024.0 as row_size_mb,
        1.0 as reduction_factor
    FROM (
        SELECT
            stay_id,
            EXTRACT(EPOCH FROM (outtime - intime))/3600 as icu_los_hours
        FROM mimiciv_icu.icustays
    ) icu_stats

    UNION ALL

    SELECT
        'Daily Output (Max per day)' as strategy,
        COUNT(DISTINCT stay_id) * AVG(icu_los_days) as estimated_rows,
        COUNT(DISTINCT stay_id) * AVG(icu_los_days) * 80.0 / 1024.0 / 1024.0 as row_size_mb,
        24.0 as reduction_factor
    FROM (
        SELECT
            stay_id,
            CEIL(EXTRACT(EPOCH FROM (outtime - intime))/3600/24.0) as icu_los_days
        FROM mimiciv_icu.icustays
    ) icu_stats

    UNION ALL

    SELECT
        'Daily Worst Only' as strategy,
        COUNT(DISTINCT stay_id) as estimated_rows,
        COUNT(DISTINCT stay_id) * 80.0 / 1024.0 / 1024.0 as row_size_mb,
        COUNT(DISTINCT stay_id) * AVG(icu_los_hours) / COUNT(DISTINCT stay_id) as reduction_factor
    FROM (
        SELECT
            stay_id,
            EXTRACT(EPOCH FROM (outtime - intime))/3600 as icu_los_hours
        FROM mimiciv_icu.icustays
    ) icu_stats
) strategy_comparison
ORDER BY estimated_size_gb;