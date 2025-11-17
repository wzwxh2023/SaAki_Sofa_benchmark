-- =================================================================
-- 性能优化后的语法验证测试
-- =================================================================

-- 测试优化后的CTE语法是否正确
WITH
-- 基础时间序列 (仅测试前10个患者，24小时)
co AS (
    SELECT
        h.stay_id,
        i.hadm_id,
        i.subject_id,
        h.hr,
        h.endtime - INTERVAL '1 HOUR' as starttime,
        h.endtime
    FROM mimiciv_derived.icustay_hourly h
    JOIN mimiciv_icu.icustays i ON h.stay_id = i.stay_id
    WHERE h.stay_id IN (
        SELECT DISTINCT stay_id
        FROM mimiciv_derived.icustay_hourly
        LIMIT 10
    )
    AND h.hr BETWEEN 0 AND 23
),

-- 测试优化后的胆红素数据CTE
bilirubin_data AS (
    SELECT
        stay.stay_id,
        enz.charttime,
        enz.bilirubin_total
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.enzyme enz ON stay.hadm_id = enz.hadm_id
    WHERE enz.bilirubin_total IS NOT NULL
        AND stay.stay_id IN (SELECT stay_id FROM co)
),

-- 测试优化后的肝脏组件
liver AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MAX(bd.bilirubin_total) > 12.0 THEN 4
            WHEN MAX(bd.bilirubin_total) > 6.0 AND MAX(bd.bilirubin_total) <= 12.0 THEN 3
            WHEN MAX(bd.bilirubin_total) > 3.0 AND MAX(bd.bilirubin_total) <= 6.0 THEN 2
            WHEN MAX(bd.bilirubin_total) > 1.2 AND MAX(bd.bilirubin_total) <= 3.0 THEN 1
            WHEN MAX(bd.bilirubin_total) IS NULL THEN NULL
            ELSE 0
        END AS liver
    FROM co
    LEFT JOIN bilirubin_data bd
        ON co.stay_id = bd.stay_id
        AND bd.charttime >= co.starttime
        AND bd.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
)

-- 验证输出
SELECT
    stay_id,
    hr,
    liver,
    '语法验证通过' AS status
FROM liver
ORDER BY stay_id, hr
LIMIT 5;