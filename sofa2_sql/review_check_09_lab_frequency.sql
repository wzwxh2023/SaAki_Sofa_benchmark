-- Review Check #9: 血小板和胆红素在 MIMIC-IV 中的检测频率
-- 确认 48h lookback 窗口的合理性

-- Part A: 同一 stay 内两次连续检测的时间间隔分布
WITH plt_intervals AS (
    SELECT
        ie.stay_id,
        cb.charttime,
        LAG(cb.charttime) OVER (PARTITION BY ie.stay_id ORDER BY cb.charttime) AS prev_time,
        EXTRACT(EPOCH FROM (cb.charttime - LAG(cb.charttime) OVER (PARTITION BY ie.stay_id ORDER BY cb.charttime))) / 3600.0 AS hours_gap
    FROM mimiciv_derived.complete_blood_count cb
    JOIN mimiciv_icu.icustays ie ON cb.hadm_id = ie.hadm_id
        AND cb.charttime >= ie.intime AND cb.charttime <= ie.outtime
    WHERE cb.platelet IS NOT NULL
),
bili_intervals AS (
    SELECT
        ie.stay_id,
        e.charttime,
        LAG(e.charttime) OVER (PARTITION BY ie.stay_id ORDER BY e.charttime) AS prev_time,
        EXTRACT(EPOCH FROM (e.charttime - LAG(e.charttime) OVER (PARTITION BY ie.stay_id ORDER BY e.charttime))) / 3600.0 AS hours_gap
    FROM mimiciv_derived.enzyme e
    JOIN mimiciv_icu.icustays ie ON e.hadm_id = ie.hadm_id
        AND e.charttime >= ie.intime AND e.charttime <= ie.outtime
    WHERE e.bilirubin_total IS NOT NULL
)

-- 血小板检测间隔分布
SELECT
    'Platelet' AS lab_type,
    COUNT(*) AS total_intervals,
    ROUND(percentile_cont(0.25) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS p25_hours,
    ROUND(percentile_cont(0.50) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS median_hours,
    ROUND(percentile_cont(0.75) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS p75_hours,
    ROUND(percentile_cont(0.90) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS p90_hours,
    ROUND(100.0 * SUM(CASE WHEN hours_gap > 24 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_gt24h,
    ROUND(100.0 * SUM(CASE WHEN hours_gap > 48 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_gt48h
FROM plt_intervals
WHERE hours_gap IS NOT NULL

UNION ALL

-- 胆红素检测间隔分布
SELECT
    'Bilirubin' AS lab_type,
    COUNT(*) AS total_intervals,
    ROUND(percentile_cont(0.25) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS p25_hours,
    ROUND(percentile_cont(0.50) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS median_hours,
    ROUND(percentile_cont(0.75) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS p75_hours,
    ROUND(percentile_cont(0.90) WITHIN GROUP (ORDER BY hours_gap)::numeric, 1) AS p90_hours,
    ROUND(100.0 * SUM(CASE WHEN hours_gap > 24 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_gt24h,
    ROUND(100.0 * SUM(CASE WHEN hours_gap > 48 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_gt48h
FROM bili_intervals
WHERE hours_gap IS NOT NULL;


-- Part B: first-day (hr 0-23) 内, 24h vs 48h lookback 的覆盖率对比
-- 有多少 stay 在 24h 内有化验值 vs 需要靠 48h 才能找到
WITH sepsis_stays AS (
    SELECT DISTINCT stay_id, hadm_id
    FROM mimiciv_icu.icustays
    WHERE stay_id IN (
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa1_delta
        UNION
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa2_delta
    )
),
plt_coverage AS (
    SELECT
        ss.stay_id,
        MAX(CASE WHEN cb.charttime >= ie.intime AND cb.charttime <= ie.intime + INTERVAL '24 HOUR'
            THEN 1 ELSE 0 END) AS has_plt_24h,
        MAX(CASE WHEN cb.charttime >= ie.intime - INTERVAL '24 HOUR' AND cb.charttime <= ie.intime + INTERVAL '24 HOUR'
            THEN 1 ELSE 0 END) AS has_plt_48h
    FROM sepsis_stays ss
    JOIN mimiciv_icu.icustays ie ON ss.stay_id = ie.stay_id
    LEFT JOIN mimiciv_derived.complete_blood_count cb
        ON ss.hadm_id = cb.hadm_id AND cb.platelet IS NOT NULL
    GROUP BY ss.stay_id
),
bili_coverage AS (
    SELECT
        ss.stay_id,
        MAX(CASE WHEN e.charttime >= ie.intime AND e.charttime <= ie.intime + INTERVAL '24 HOUR'
            THEN 1 ELSE 0 END) AS has_bili_24h,
        MAX(CASE WHEN e.charttime >= ie.intime - INTERVAL '24 HOUR' AND e.charttime <= ie.intime + INTERVAL '24 HOUR'
            THEN 1 ELSE 0 END) AS has_bili_48h
    FROM sepsis_stays ss
    JOIN mimiciv_icu.icustays ie ON ss.stay_id = ie.stay_id
    LEFT JOIN mimiciv_derived.enzyme e
        ON ss.hadm_id = e.hadm_id AND e.bilirubin_total IS NOT NULL
    GROUP BY ss.stay_id
)
SELECT
    'Platelet' AS lab_type,
    COUNT(*) AS total_sepsis_stays,
    SUM(has_plt_24h) AS covered_24h,
    ROUND(100.0 * SUM(has_plt_24h) / COUNT(*), 1) AS pct_24h,
    SUM(has_plt_48h) AS covered_48h,
    ROUND(100.0 * SUM(has_plt_48h) / COUNT(*), 1) AS pct_48h,
    SUM(has_plt_48h) - SUM(has_plt_24h) AS extra_from_48h
FROM plt_coverage

UNION ALL

SELECT
    'Bilirubin' AS lab_type,
    COUNT(*) AS total_sepsis_stays,
    SUM(has_bili_24h) AS covered_24h,
    ROUND(100.0 * SUM(has_bili_24h) / COUNT(*), 1) AS pct_24h,
    SUM(has_bili_48h) AS covered_48h,
    ROUND(100.0 * SUM(has_bili_48h) / COUNT(*), 1) AS pct_48h,
    SUM(has_bili_48h) - SUM(has_bili_24h) AS extra_from_48h
FROM bili_coverage;
