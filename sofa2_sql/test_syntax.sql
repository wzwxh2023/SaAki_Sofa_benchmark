-- 简化的语法测试脚本，仅验证前几个CTE是否能正常执行
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 1
        AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 5)
)

-- 测试GCS数据访问
, gcs_clean AS (
    SELECT
        gcs.stay_id,
        gcs.charttime,
        gcs.gcs
    FROM mimiciv_derived.gcs gcs
    WHERE gcs.gcs IS NOT NULL
    LIMIT 10
)

-- 测试呼吸数据访问
, respiratory_test AS (
    SELECT
        stay_id,
        ventilation_status,
        starttime,
        endtime
    FROM mimiciv_derived.ventilation
    WHERE ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC')
    LIMIT 10
)

-- 测试血管活性药物数据访问
, vaso_test AS (
    SELECT
        stay_id,
        starttime,
        norepinephrine,
        epinephrine
    FROM mimiciv_derived.vasoactive_agent
    WHERE norepinephrine IS NOT NULL OR epinephrine IS NOT NULL
    LIMIT 10
)

-- 最终测试输出
SELECT
    'TEST_PASSED' as status,
    COUNT(DISTINCT co.stay_id) as test_stays,
    COUNT(DISTINCT gcs.stay_id) as gcs_records,
    COUNT(DISTINCT r.stay_id) as ventilation_records,
    COUNT(DISTINCT v.stay_id) as vaso_records
FROM co
LEFT JOIN gcs_clean gcs ON 1=1
LEFT JOIN respiratory_test r ON 1=1
LEFT JOIN vaso_test v ON 1=1;