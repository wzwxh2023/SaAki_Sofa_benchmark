-- =================================================================
-- SOFA时间序列分析：验证序贯SOFA2的预测性能
-- 对比原文方法的"ICU day 1 to day 7"分析
-- =================================================================

WITH time_series_sofa AS (
    SELECT
        ie.stay_id,
        ie.subject_id,
        ie.intime,
        ie.outtime,
        ie.hadm_id,
        ie.los as icu_los_days,
        -- 提取前7天每天的SOFA和SOFA2评分
        -- 第1天（入院当天）
        ROUND(AVG(CASE WHEN s.sofa IS NOT NULL AND
                        s.starttime >= ie.intime - INTERVAL '6 hours' AND
                        s.starttime < ie.intime + INTERVAL '1 days'
                   THEN s.sofa END), 2) as sofa_day1,
        ROUND(AVG(CASE WHEN s2.sofa2_total IS NOT NULL AND
                        s2.starttime >= ie.intime - INTERVAL '6 hours' AND
                        s2.starttime < ie.intime + INTERVAL '1 days'
                   THEN s2.sofa2_total END), 2) as sofa2_day1,

        -- 第2天
        ROUND(AVG(CASE WHEN s.sofa IS NOT NULL AND
                        s.starttime >= ie.intime + INTERVAL '1 days' AND
                        s.starttime < ie.intime + INTERVAL '2 days'
                   THEN s.sofa END), 2) as sofa_day2,
        ROUND(AVG(CASE WHEN s2.sofa2_total IS NOT NULL AND
                        s2.starttime >= ie.intime + INTERVAL '1 days' AND
                        s2.starttime < ie.intime + INTERVAL '2 days'
                   THEN s2.sofa2_total END), 2) as sofa2_day2,

        -- 第3天
        ROUND(AVG(CASE WHEN s.sofa IS NOT NULL AND
                        s.starttime >= ie.intime + INTERVAL '2 days' AND
                        s.starttime < ie.intime + INTERVAL '3 days'
                   THEN s.sofa END), 2) as sofa_day3,
        ROUND(AVG(CASE WHEN s2.sofa2_total IS NOT NULL AND
                        s2.starttime >= ie.intime + INTERVAL '2 days' AND
                        s2.starttime < ie.intime + INTERVAL '3 days'
                   THEN s2.sofa2_total END), 2) as sofa2_day3,

        -- 第4天
        ROUND(AVG(CASE WHEN s.sofa IS NOT NULL AND
                        s.starttime >= ie.intime + INTERVAL '3 days' AND
                        s.starttime < ie.intime + INTERVAL '4 days'
                   THEN s.sofa END), 2) as sofa_day4,
        ROUND(AVG(CASE WHEN s2.sofa2_total IS NOT NULL AND
                        s2.starttime >= ie.intime + INTERVAL '3 days' AND
                        s2.starttime < ie.intime + INTERVAL '4 days'
                   THEN s2.sofa2_total END), 2) as sofa2_day4,

        -- 第5天
        ROUND(AVG(CASE WHEN s.sofa IS NOT NULL AND
                        s.starttime >= ie.intime + INTERVAL '4 days' AND
                        s.starttime < ie.intime + INTERVAL '5 days'
                   THEN s.sofa END), 2) as sofa_day5,
        ROUND(AVG(CASE WHEN s2.sofa2_total IS NOT NULL AND
                        s2.starttime >= ie.intime + INTERVAL '4 days' AND
                        s2.starttime < ie.intime + INTERVAL '5 days'
                   THEN s2.sofa2_total END), 2) as sofa2_day5,

        -- 第6天
        ROUND(AVG(CASE WHEN s.sofa IS NOT NULL AND
                        s.starttime >= ie.intime + INTERVAL '5 days' AND
                        s.starttime < ie.intime + INTERVAL '6 days'
                   THEN s.sofa END), 2) as sofa_day6,
        ROUND(AVG(CASE WHEN s2.sofa2_total IS NOT NULL AND
                        s2.starttime >= ie.intime + INTERVAL '5 days' AND
                        s2.starttime < ie.intime + INTERVAL '6 days'
                   THEN s2.sofa2_total END), 2) as sofa2_day6,

        -- 第7天
        ROUND(AVG(CASE WHEN s.sofa IS NOT NULL AND
                        s.starttime >= ie.intime + INTERVAL '6 days' AND
                        s.starttime < ie.intime + INTERVAL '7 days'
                   THEN s.sofa END), 2) as sofa_day7,
        ROUND(AVG(CASE WHEN s2.sofa2_total IS NOT NULL AND
                        s2.starttime >= ie.intime + INTERVAL '6 days' AND
                        s2.starttime < ie.intime + INTERVAL '7 days'
                   THEN s2.sofa2_total END), 2) as sofa2_day7,

        -- 死亡结局
        CASE WHEN ie.deathtime IS NOT NULL AND ie.deathtime <= ie.outtime
             THEN 1 ELSE 0 END as icu_mortality

    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.first_day_sofa s ON ie.stay_id = s.stay_id
    LEFT JOIN mimiciv_derived.sofa2_scores s2 ON ie.stay_id = s2.stay_id
    WHERE ie.los >= 7  -- 只分析住院>=7天的患者
    GROUP BY ie.stay_id, ie.subject_id, ie.intime, ie.outtime, ie.hadm_id, ie.los, ie.deathtime
)

SELECT
    '时间序列数据统计' as analysis_type,
    COUNT(*) as total_patients,
    COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) as icu_deaths,
    ROUND(COUNT(CASE WHEN icu_mortality = 1 THEN 1 END) * 100.0 / COUNT(*), 2) as mortality_rate,
    ROUND(AVG(sofa_day1), 2) as avg_sofa_d1,
    ROUND(AVG(sofa2_day1), 2) as avg_sofa2_d1,
    ROUND(AVG(sofa_day7), 2) as avg_sofa_d7,
    ROUND(AVG(sofa2_day7), 2) as avg_sofa2_d7
FROM time_series_sofa
WHERE sofa_day1 IS NOT NULL AND sofa2_day1 IS NOT NULL;

-- 导出时间序列数据用于Python AUC分析
COPY (
    SELECT
        stay_id,
        subject_id,
        icu_los_days,
        icu_mortality,
        sofa_day1, sofa2_day1,
        sofa_day2, sofa2_day2,
        sofa_day3, sofa2_day3,
        sofa_day4, sofa2_day4,
        sofa_day5, sofa2_day5,
        sofa_day6, sofa2_day6,
        sofa_day7, sofa2_day7,
        -- 计算SOFA评分变化趋势
        sofa_day7 - sofa_day1 as sofa_change_d7_d1,
        sofa2_day7 - sofa2_day1 as sofa2_change_d7_d1,
        -- 计算平均SOFA评分（模拟原文方法）
        ROUND((sofa_day1 + sofa_day2 + sofa_day3 + sofa_day4 + sofa_day5 + sofa_day6 + sofa_day7) / 7, 2) as sofa_avg_7d,
        ROUND((sofa2_day1 + sofa2_day2 + sofa2_day3 + sofa2_day4 + sofa2_day5 + sofa2_day6 + sofa2_day7) / 7, 2) as sofa2_avg_7d
    FROM time_series_sofa
    WHERE sofa_day1 IS NOT NULL AND sofa2_day1 IS NOT NULL
    ORDER BY subject_id
) TO '/tmp/sofa_time_series_data.csv' WITH CSV HEADER;

SELECT '=== 时间序列数据导出完成 ===' as status,
       '文件路径: /tmp/sofa_time_series_data.csv' as file_location,
       '可用于Python进行序贯AUC分析' as next_step;