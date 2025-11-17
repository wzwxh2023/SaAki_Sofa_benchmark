-- 验证MIMIC-IV中GCS数据完整性
-- 分析GCS缺失情况和当前回溯逻辑的充分性

-- 1. GCS数据覆盖度统计
SELECT
    'GCS Coverage Analysis' as analysis_type,
    COUNT(DISTINCT icu.stay_id) as total_icu_stays,
    COUNT(DISTINCT gcs.stay_id) as stays_with_gcs,
    ROUND(COUNT(DISTINCT gcs.stay_id) * 100.0 / COUNT(DISTINCT icu.stay_id), 2) as coverage_pct,
    COUNT(*) as total_gcs_records,
    COUNT(CASE WHEN gcs.gcs IS NULL THEN 1 END) as null_gcs_records,
    ROUND(AVG(gcs.gcs), 1) as avg_gcs,
    MIN(gcs.gcs) as min_gcs,
    MAX(gcs.gcs) as max_gcs
FROM mimiciv_icu.icustays icu
LEFT JOIN mimiciv_derived.gcs gcs ON icu.stay_id = gcs.stay_id;

-- 2. GCS各分域的可用性分析
SELECT
    'GCS Component Availability' as analysis_type,
    COUNT(CASE WHEN gcs.gcs IS NOT NULL THEN 1 END) as total_gcs_available,
    COUNT(CASE WHEN gcs.gcs_motor IS NOT NULL THEN 1 END) as motor_available,
    COUNT(CASE WHEN gcs.gcs_verbal IS NOT NULL THEN 1 END) as verbal_available,
    COUNT(CASE WHEN gcs.gcs_eyes IS NOT NULL THEN 1 END) as eyes_available,
    ROUND(COUNT(CASE WHEN gcs.gcs IS NOT NULL THEN 1 END) * 100.0 / COUNT(*), 2) as gcs_completeness_pct,
    ROUND(COUNT(CASE WHEN gcs.gcs_motor IS NOT NULL THEN 1 END) * 100.0 / COUNT(*), 2) as motor_completeness_pct,
    ROUND(COUNT(CASE WHEN gcs.gcs_verbal IS NOT NULL THEN 1 END) * 100.0 / COUNT(*), 2) as verbal_completeness_pct,
    ROUND(COUNT(CASE WHEN gcs.gcs_eyes IS NOT NULL THEN 1 END) * 100.0 / COUNT(*), 2) as eyes_completeness_pct
FROM mimiciv_derived.gcs gcs
WHERE gcs.stay_id IN (SELECT stay_id FROM mimiciv_icu.icustays LIMIT 1000);  -- 样本数据用于快速测试

-- 3. GCS缺失模式分析
SELECT
    'GCS Missing Patterns' as analysis_type,
    'Complete GCS missing' as pattern,
    COUNT(CASE WHEN gcs.gcs IS NULL AND gcs.gcs_motor IS NULL AND gcs.gcs_verbal IS NULL AND gcs.gcs_eyes IS NULL THEN 1 END) as count,
    ROUND(COUNT(CASE WHEN gcs.gcs IS NULL AND gcs.gcs_motor IS NULL AND gcs.gcs_verbal IS NULL AND gcs.gcs_eyes IS NULL THEN 1 END) * 100.0 / COUNT(*), 2) as pct
FROM mimiciv_derived.gcs gcs
WHERE gcs.stay_id IN (SELECT stay_id FROM mimiciv_icu.icustays LIMIT 1000)

UNION ALL

SELECT
    'GCS Missing Patterns' as analysis_type,
    'Only motor available' as pattern,
    COUNT(CASE WHEN gcs.gcs IS NULL AND gcs.gcs_motor IS NOT NULL AND gcs.gcs_verbal IS NULL AND gcs.gcs_eyes IS NULL THEN 1 END) as count,
    ROUND(COUNT(CASE WHEN gcs.gcs IS NULL AND gcs.gcs_motor IS NOT NULL AND gcs.gcs_verbal IS NULL AND gcs.gcs_eyes IS NULL THEN 1 END) * 100.0 / COUNT(*), 2) as pct
FROM mimiciv_derived.gcs gcs
WHERE gcs.stay_id IN (SELECT stay_id FROM mimiciv_icu.icustays LIMIT 1000)

UNION ALL

SELECT
    'GCS Missing Patterns' as analysis_type,
    'Partial GCS missing' as pattern,
    COUNT(CASE WHEN (gcs.gcs_motor IS NULL OR gcs.gcs_verbal IS NULL OR gcs.gcs_eyes IS NULL) AND gcs.gcs IS NOT NULL THEN 1 END) as count,
    ROUND(COUNT(CASE WHEN (gcs.gcs_motor IS NULL OR gcs.gcs_verbal IS NULL OR gcs.gcs_eyes IS NULL) AND gcs.gcs IS NOT NULL THEN 1 END) * 100.0 / COUNT(*), 2) as pct
FROM mimiciv_derived.gcs gcs
WHERE gcs.stay_id IN (SELECT stay_id FROM mimiciv_icu.icustays LIMIT 1000);

-- 4. 镇静状态对GCS可用性的影响
SELECT
    'Sedation Impact on GCS' as analysis_type,
    COUNT(*) as total_records,
    COUNT(CASE WHEN gcs.gcs IS NULL THEN 1 END) as missing_gcs_when_sedated,
    ROUND(COUNT(CASE WHEN gcs.gcs IS NULL THEN 1 END) * 100.0 / COUNT(*), 2) as missing_pct_when_sedated
FROM mimiciv_derived.gcs gcs
WHERE gcs.stay_id IN (
    SELECT DISTINCT stay_id FROM mimiciv_icu.icustays LIMIT 500
) AND EXISTS (
    SELECT 1 FROM mimiciv_hosp.prescriptions pr
    JOIN mimiciv_icu.icustays icu ON pr.hadm_id = icu.hadm_id
    WHERE icu.stay_id = gcs.stay_id
    AND pr.starttime <= gcs.charttime
    AND COALESCE(pr.stoptime, gcs.charttime + INTERVAL '1 minute') > gcs.charttime
    AND LOWER(pr.drug) LIKE '%propofol%'  -- 仅检查丙泊酚作为示例
);

-- 5. 当前回溯逻辑的覆盖度验证
WITH RECURSIVE hourly_timeline AS (
    SELECT stay_id, intime, outtime, 0 as hr
    FROM mimiciv_icu.icustays
    WHERE stay_id IN (SELECT stay_id FROM mimiciv_icu.icustays LIMIT 100)

    UNION ALL

    SELECT stay_id, intime, outtime, hr + 1
    FROM hourly_timeline
    WHERE hr + 1 <= FLOOR(EXTRACT(EPOCH FROM (outtime - intime))/3600)
),
gcs_lookup AS (
    SELECT
        ht.stay_id,
        ht.hr,
        ht.intime + INTERVAL '1 hour' * ht.hr as hour_start,
        ht.intime + INTERVAL '1 hour' * (ht.hr + 1) as hour_end,
        gcs.gcs,
        gcs.gcs_motor,
        gcs.charttime as gcs_time,
        CASE
            WHEN gcs.gcs IS NOT NULL THEN 'Complete GCS found'
            WHEN gcs.gcs_motor IS NOT NULL THEN 'Only motor found'
            ELSE 'No GCS data'
        END as availability_status
    FROM hourly_timeline ht
    LEFT JOIN mimiciv_derived.gcs gcs ON ht.stay_id = gcs.stay_id
        AND gcs.charttime < ht.intime + INTERVAL '1 hour' * (ht.hr + 1)
    WHERE ht.hr <= 24  -- 只检查前24小时
)
SELECT
    'Current Logic Coverage' as analysis_type,
    COUNT(*) as total_hours,
    COUNT(CASE WHEN availability_status = 'Complete GCS found' THEN 1 END) as hours_with_complete_gcs,
    COUNT(CASE WHEN availability_status = 'Only motor found' THEN 1 END) as hours_with_motor_only,
    COUNT(CASE WHEN availability_status = 'No GCS data' THEN 1 END) as hours_without_gcs,
    ROUND(COUNT(CASE WHEN availability_status = 'Complete GCS found' THEN 1 END) * 100.0 / COUNT(*), 2) as complete_coverage_pct,
    ROUND((COUNT(CASE WHEN availability_status = 'Complete GCS found' THEN 1 END) + COUNT(CASE WHEN availability_status = 'Only motor found' THEN 1 END)) * 100.0 / COUNT(*), 2) as any_gcs_coverage_pct
FROM gcs_lookup;