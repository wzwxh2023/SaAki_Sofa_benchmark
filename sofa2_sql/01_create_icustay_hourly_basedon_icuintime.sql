-- =================================================================
-- 创建基于ICU入院时间的hourly表 - 修复版
--
-- 功能：创建一个与官方icustay_hourly结构完全相同的表，
--       但时间基准从第一次心率测量改为ICU入院时间
--
-- 修改说明：
-- - 基准时间：从 icustay_times.intime_hr 改为 icustays.intime
-- - hr=0 现在对应 ICU 入院时间（向上取整到下一整点）
-- - 修复：处理outtime为NULL的情况，使用最后一次Chartevents时间
--
-- 使用方法：
-- 1. 运行此脚本创建新表
-- 2. 在后续SOFA2计算中替换 icustay_hourly 为 icustay_hourly_basedon_icuintime
--
-- 注意：此表创建后，SOFA2的 hr 0-23 将正确对应ICU入院后24小时
-- =================================================================

DROP TABLE IF EXISTS mimiciv_derived.icustay_hourly_basedon_icuintime CASCADE;

-- 首先创建一个视图来获取每个ICU停留的最后记录时间
CREATE OR REPLACE TEMP VIEW last_icu_time AS
SELECT
    stay_id,
    MAX(charttime) as last_charttime
FROM mimiciv_icu.chartevents
WHERE stay_id IN (
    SELECT stay_id
    FROM mimiciv_icu.icustays
    WHERE outtime IS NULL
)
GROUP BY stay_id;

CREATE TABLE mimiciv_derived.icustay_hourly_basedon_icuintime AS
/* This query generates a row for every hour the patient is in the ICU. */
/* The hours are based on clock-hours (i.e. 02:00, 03:00). */
/* The hour clock starts 24 hours before ICU admission time. */
/* Note that the time of ICU admission is ceilinged to the hour. */
/* this query extracts the cohort and every possible hour they were in the ICU */
/* this table can be to other tables on stay_id and (ENDTIME - 1 hour,ENDTIME] */
WITH all_hours AS (
  SELECT
    ie.stay_id,
    /* round the ICU admission intime up to the nearest hour */
    CASE
      WHEN DATE_TRUNC('HOUR', ie.intime) = ie.intime
      THEN ie.intime
      ELSE DATE_TRUNC('HOUR', ie.intime) + INTERVAL '1 HOUR'
    END AS endtime,
    /* create integers for each charttime in hours from ICU admission */
    /* so 0 is ICU admission time, 1 is one hour after admission, etc, */
    /* up to ICU disch */
    /*  we allow 24 hours before ICU admission (to grab labs before admit) */
    CASE
      WHEN ie.outtime IS NOT NULL THEN
        ARRAY(SELECT *
        FROM GENERATE_SERIES(-24, CAST(CEIL(EXTRACT(EPOCH FROM (ie.outtime - ie.intime)) / 3600.0) AS INT)))
      ELSE
        -- 对于outtime为NULL的患者，使用最后一次chartevents时间
        -- 确保至少有24小时的数据用于first day评分
        ARRAY(SELECT *
        FROM GENERATE_SERIES(-24, GREATEST(
            CAST(CEIL(EXTRACT(EPOCH FROM (COALESCE(lt.last_charttime, ie.intime + INTERVAL '7 days')) - ie.intime)) / 3600.0 AS INT),
            24  -- 至少生成前24小时
        )))
    END AS hrs
  FROM mimiciv_icu.icustays ie
  LEFT JOIN last_icu_time lt ON ie.stay_id = lt.stay_id
)
SELECT
  stay_id,
  CAST(hr_unnested AS BIGINT) AS hr,
  endtime + CAST(hr_unnested AS BIGINT) * INTERVAL '1 HOUR' AS endtime
FROM all_hours
CROSS JOIN UNNEST(all_hours.hrs) AS _t0(hr_unnested);

-- 创建索引（与官方表保持一致）
CREATE INDEX idx_icustay_hourly_basedon_icuintime_stay_hr
    ON mimiciv_derived.icustay_hourly_basedon_icuintime(stay_id, hr);

CREATE INDEX idx_icustay_hourly_basedon_icuintime_endtime
    ON mimiciv_derived.icustay_hourly_basedon_icuintime(endtime);

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.icustay_hourly_basedon_icuintime IS
    'ICU hourly time series based on ICU admission time (not first heart rate measurement)';
COMMENT ON COLUMN mimiciv_derived.icustay_hourly_basedon_icuintime.hr IS
    'Hours relative to ICU admission (hr=0 is the first hour after ICU admission)';
COMMENT ON COLUMN mimiciv_derived.icustay_hourly_basedon_icuintime.endtime IS
    'End time of the hour interval';

-- 显示创建结果
SELECT
    'icustay_hourly_basedon_icuintime created' as status,
    COUNT(*) as total_rows,
    COUNT(DISTINCT stay_id) as unique_stays,
    MIN(hr) as min_hr,
    MAX(hr) as max_hr
FROM mimiciv_derived.icustay_hourly_basedon_icuintime;

-- 清理临时视图
DROP VIEW IF EXISTS last_icu_time;