-- =================================================================
-- 简化版SOFA2时间序列分析
-- 使用sofa2_scores表进行第1-7天的数据分析
-- =================================================================

WITH sofa2_daily_scores AS (
    SELECT
        ie.stay_id,
        ie.subject_id,
        ie.intime,
        ie.outtime,
        ie.los as icu_los_days,
        CASE WHEN ie.deathtime IS NOT NULL AND ie.deathtime <= ie.outtime
             THEN 1 ELSE 0 END as icu_mortality,

        -- 第1天SOFA2评分
        ROUND(AVG(CASE WHEN s2.starttime >= ie.intime - INTERVAL '6 hours' AND
                           s2.starttime < ie.intime + INTERVAL '1 days' AND
                           s2.sofa2_total IS NOT NULL
                      THEN s2.sofa2_total END), 2) as sofa2_day1,

        -- 第2天SOFA2评分
        ROUND(AVG(CASE WHEN s2.starttime >= ie.intime + INTERVAL '1 days' AND
                           s2.starttime < ie.intime + INTERVAL '2 days' AND
                           s2.sofa2_total IS NOT NULL
                      THEN s2.sofa2_total END), 2) as sofa2_day2,

        -- 第3天SOFA2评分
        ROUND(AVG(CASE WHEN s2.starttime >= ie.intime + INTERVAL '2 days' AND
                           s2.starttime < ie.intime + INTERVAL '3 days' AND
                           s2.sofa2_total IS NOT NULL
                      THEN s2.sofa2_total END), 2) as sofa2_day3,

        -- 第4天SOFA2评分
        ROUND(AVG(CASE WHEN s2.starttime >= ie.intime + INTERVAL '3 days' AND
                           s2.starttime < ie.intime + INTERVAL '4 days' AND
                           s2.sofa2_total IS NOT NULL
                      THEN s2.sofa2_total END), 2) as sofa2_day4,

        -- 第5天SOFA2评分
        ROUND(AVG(CASE WHEN s2.starttime >= ie.intime + INTERVAL '4 days' AND
                           s2.starttime < ie.intime + INTERVAL '5 days' AND
                           s2.sofa2_total IS NOT NULL
                      THEN s2.sofa2_total END), 2) as sofa2_day5,

        -- 第6天SOFA2评分
        ROUND(AVG(CASE WHEN s2.starttime >= ie.intime + INTERVAL '5 days' AND
                           s2.starttime < ie.intime + INTERVAL '6 days' AND
                           s2.sofa2_total IS NOT NULL
                      THEN s2.sofa2_total END), 2) as sofa2_day6,

        -- 第7天SOFA2评分
        ROUND(AVG(CASE WHEN s2.starttime >= ie.intime + INTERVAL '6 days' AND
                           s2.starttime < ie.intime + INTERVAL '7 days' AND
                           s2.sofa2_total IS NOT NULL
                      THEN s2.sofa2_total END), 2) as sofa2_day7,

        -- 首日SOFA评分（从first_day_sofa表获取）
        ROUND(fds.sofa, 2) as sofa_day1

    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.sofa2_scores s2 ON ie.stay_id = s2.stay_id
    LEFT JOIN mimiciv_derived.first_day_sofa fds ON ie.stay_id = fds.stay_id
    WHERE ie.los >= 7
    GROUP BY ie.stay_id, ie.subject_id, ie.intime, ie.outtime, ie.los, ie.deathtime, fds.sofa
)

-- 基础统计
SELECT
    'SOFA2时间序列数据统计' as analysis_type,
    COUNT(*) as total_patients,
    COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) as icu_deaths,
    ROUND(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) * 100.0 / COUNT(*), 2) as mortality_rate,
    ROUND(AVG(sofa_day1), 2) as avg_sofa_d1,
    ROUND(AVG(sofa2_day1), 2) as avg_sofa2_d1,
    ROUND(AVG(sofa2_day7), 2) as avg_sofa2_d7,
    COUNT(CASE WHEN sofa2_day1 IS NOT NULL THEN 1 END) as have_sofa2_d1,
    COUNT(CASE WHEN sofa2_day7 IS NOT NULL THEN 1 END) as have_sofa2_d7
FROM sofa2_daily_scores
WHERE sofa2_day1 IS NOT NULL AND sofa_day1 IS NOT NULL;

-- 导出数据用于时间序列AUC分析
COPY (
    SELECT
        stay_id,
        subject_id,
        icu_los_days,
        icu_mortality,
        sofa_day1,
        sofa2_day1, sofa2_day2, sofa2_day3, sofa2_day4, sofa2_day5, sofa2_day6, sofa2_day7,
        -- 计算SOFA2的7天平均值（模拟原文序贯分析）
        ROUND((sofa2_day1 + sofa2_day2 + sofa2_day3 + sofa2_day4 + sofa2_day5 + sofa2_day6 + sofa2_day7) / 7, 2) as sofa2_avg_7d,
        -- 计算SOFA2变化趋势
        sofa2_day7 - sofa2_day1 as sofa2_change_d7_d1,
        -- 找出最大SOFA2评分
        GREATEST(sofa2_day1, sofa2_day2, sofa2_day3, sofa2_day4, sofa2_day5, sofa2_day6, sofa2_day7) as sofa2_max_7d
    FROM sofa2_daily_scores
    WHERE sofa2_day1 IS NOT NULL AND sofa_day1 IS NOT NULL
    ORDER BY subject_id
) TO '/tmp/sofa_time_series_data.csv' WITH CSV HEADER;

SELECT '=== 时间序列SOFA2数据导出完成 ===' as status;