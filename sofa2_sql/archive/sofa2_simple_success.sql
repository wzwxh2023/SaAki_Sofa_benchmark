-- =================================================================
-- SOFA2 简化保证成功版本
-- 使用最高性能配置，确保100%执行成功
-- =================================================================

-- 超级性能配置
SET work_mem = '2047MB';
SET maintenance_work_mem = '2047MB';
SET effective_cache_size = '70GB';
SET max_parallel_workers = 24;
SET max_parallel_workers_per_gather = 12;
SET parallel_leader_participation = on;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
SET enable_parallel_hash = on;
SET jit = off;
SET statement_timeout = '7200s';

-- 显示优化配置
SELECT
    'SOFA2 高性能配置' AS status,
    current_setting('work_mem') AS work_mem,
    current_setting('max_parallel_workers_per_gather') AS parallel_workers,
    current_setting('effective_cache_size') AS cache_size;

-- 删除现有V3表（如果存在）
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores_v3 CASCADE;

-- 直接基于现有数据创建新表 - 保证成功
CREATE TABLE mimiciv_derived.sofa2_scores_v3 AS
SELECT
    ih.stay_id,
    icu.hadm_id,
    icu.subject_id,
    ih.hr,
    ih.endtime - INTERVAL '1 HOUR' AS starttime,
    ih.endtime,

    -- 神经系统评分 (GCS) - 简化版本
    CASE WHEN gcs_min.gcs <= 5 THEN 4
         WHEN gcs_min.gcs <= 8 THEN 3
         WHEN gcs_min.gcs <= 12 THEN 2
         WHEN gcs_min.gcs <= 14 THEN 1
         ELSE 0 END AS brain,

    -- 呼吸系统评分 - 简化版本
    CASE WHEN bg_min.pao2fio2ratio <= 100 THEN 4
         WHEN bg_min.pao2fio2ratio <= 200 THEN 3
         WHEN bg_min.pao2fio2ratio <= 300 THEN 2
         WHEN bg_min.pao2fio2ratio <= 400 THEN 1
         ELSE 0 END AS respiratory,

    -- 心血管系统评分 - 简化版本
    CASE WHEN vas_max.pressor_level >= 3 THEN 4
         WHEN vas_max.pressor_level >= 2 THEN 3
         WHEN vas_max.pressor_level >= 1 THEN 2
         ELSE 0 END AS cardiovascular,

    -- 肝脏系统评分 - 简化版本
    CASE WHEN enz_max.bilirubin_total > 12.0 THEN 4
         WHEN enz_max.bilirubin_total > 6.0 THEN 3
         WHEN enz_max.bilirubin_total > 2.0 THEN 2
         WHEN enz_max.bilirubin_total > 1.2 THEN 1
         ELSE 0 END AS liver,

    -- 肾脏系统评分 - 简化版本
    CASE WHEN rrt_max.has_rrt = 1 THEN 4
         WHEN chem_max.creatinine > 5.0 THEN 4
         WHEN chem_max.creatinine > 3.5 THEN 3
         WHEN chem_max.creatinine > 2.0 THEN 2
         WHEN chem_max.creatinine > 1.2 THEN 1
         ELSE 0 END AS kidney,

    -- 凝血系统评分 - 简化版本
    CASE WHEN cbc_min.platelet <= 50 THEN 4
         WHEN cbc_min.platelet <= 80 THEN 3
         WHEN cbc_min.platelet <= 100 THEN 2
         WHEN cbc_min.platelet <= 150 THEN 1
         ELSE 0 END AS hemostasis,

    -- SOFA2总分
    (CASE WHEN gcs_min.gcs <= 5 THEN 4
          WHEN gcs_min.gcs <= 8 THEN 3
          WHEN gcs_min.gcs <= 12 THEN 2
          WHEN gcs_min.gcs <= 14 THEN 1
          ELSE 0 END) +
    (CASE WHEN bg_min.pao2fio2ratio <= 100 THEN 4
          WHEN bg_min.pao2fio2ratio <= 200 THEN 3
          WHEN bg_min.pao2fio2ratio <= 300 THEN 2
          WHEN bg_min.pao2fio2ratio <= 400 THEN 1
          ELSE 0 END) +
    (CASE WHEN vas_max.pressor_level >= 3 THEN 4
          WHEN vas_max.pressor_level >= 2 THEN 3
          WHEN vas_max.pressor_level >= 1 THEN 2
          ELSE 0 END) +
    (CASE WHEN enz_max.bilirubin_total > 12.0 THEN 4
          WHEN enz_max.bilirubin_total > 6.0 THEN 3
          WHEN enz_max.bilirubin_total > 2.0 THEN 2
          WHEN enz_max.bilirubin_total > 1.2 THEN 1
          ELSE 0 END) +
    (CASE WHEN rrt_max.has_rrt = 1 THEN 4
          WHEN chem_max.creatinine > 5.0 THEN 4
          WHEN chem_max.creatinine > 3.5 THEN 3
          WHEN chem_max.creatinine > 2.0 THEN 2
          WHEN chem_max.creatinine > 1.2 THEN 1
          ELSE 0 END) +
    (CASE WHEN cbc_min.platelet <= 50 THEN 4
          WHEN cbc_min.platelet <= 80 THEN 3
          WHEN cbc_min.platelet <= 100 THEN 2
          WHEN cbc_min.platelet <= 150 THEN 1
          ELSE 0 END) AS sofa2_total

FROM mimiciv_derived.icustay_hourly ih
INNER JOIN mimiciv_icu.icustays icu ON ih.stay_id = icu.stay_id

-- GCS评分获取
LEFT JOIN LATERAL (
    SELECT MIN(gcs.gcs) AS gcs
    FROM mimiciv_derived.gcs gcs
    WHERE gcs.stay_id = ih.stay_id
      AND gcs.charttime >= (ih.endtime - INTERVAL '1 HOUR')
      AND gcs.charttime < ih.endtime
      AND gcs.gcs IS NOT NULL
) gcs_min ON TRUE

-- 血气分析获取
LEFT JOIN LATERAL (
    SELECT MIN(bg.pao2fio2ratio) AS pao2fio2ratio
    FROM mimiciv_derived.bg bg
    WHERE bg.subject_id = ih.stay_id  -- 使用subject_id连接
      AND bg.charttime >= (ih.endtime - INTERVAL '1 HOUR')
      AND bg.charttime < ih.endtime
      AND bg.specimen = 'ART.'
      AND bg.pao2fio2ratio > 0
) bg_min ON TRUE

-- 血管活性药物获取
LEFT JOIN LATERAL (
    SELECT MAX(
        CASE WHEN va.norepinephrine > 0 OR va.epinephrine > 0 THEN 3
             WHEN va.dopamine > 15 THEN 2
             WHEN va.dopamine > 0 OR va.dobutamine > 0 THEN 1
             ELSE 0 END
    ) AS pressor_level
    FROM mimiciv_derived.vasoactive_agent va
    WHERE va.stay_id = ih.stay_id
      AND va.starttime < ih.endtime
      AND COALESCE(va.endtime, ih.endtime) >= (ih.endtime - INTERVAL '1 HOUR')
) vas_max ON TRUE

-- 肝功能获取
LEFT JOIN LATERAL (
    SELECT MAX(enz.bilirubin_total) AS bilirubin_total
    FROM mimiciv_derived.enzyme enz
    WHERE enz.hadm_id = icu.hadm_id  -- 使用hadm_id连接
      AND enz.charttime >= (ih.endtime - INTERVAL '1 HOUR')
      AND enz.charttime < ih.endtime
) enz_max ON TRUE

-- 肾功能获取
LEFT JOIN LATERAL (
    SELECT MAX(chem.creatinine) AS creatinine
    FROM mimiciv_derived.chemistry chem
    WHERE chem.hadm_id = icu.hadm_id  -- 使用hadm_id连接
      AND chem.charttime >= (ih.endtime - INTERVAL '1 HOUR')
      AND chem.charttime < ih.endtime
) chem_max ON TRUE

-- RRT状态获取
LEFT JOIN LATERAL (
    SELECT MAX(CASE WHEN rrt.dialysis_present = 1 THEN 1 ELSE 0 END) AS has_rrt
    FROM mimiciv_derived.rrt rrt
    WHERE rrt.stay_id = ih.stay_id
      AND rrt.charttime >= (ih.endtime - INTERVAL '1 HOUR')
      AND rrt.charttime < ih.endtime
) rrt_max ON TRUE

-- 血小板获取
LEFT JOIN LATERAL (
    SELECT MIN(cbc.platelet) AS platelet
    FROM mimiciv_derived.complete_blood_count cbc
    WHERE cbc.hadm_id = icu.hadm_id  -- 使用hadm_id连接
      AND cbc.charttime >= (ih.endtime - INTERVAL '1 HOUR')
      AND cbc.charttime < ih.endtime
) cbc_min ON TRUE

WHERE ih.hr >= 0;

-- 创建主键
ALTER TABLE mimiciv_derived.sofa2_scores_v3
ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;

-- 创建性能索引
CREATE INDEX CONCURRENTLY idx_sofa2_v3_stay_id ON mimiciv_derived.sofa2_scores_v3(stay_id);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_subject_id ON mimiciv_derived.sofa2_scores_v3(subject_id);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_total_score ON mimiciv_derived.sofa2_scores_v3(sofa2_total);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_hadm_id ON mimiciv_derived.sofa2_scores_v3(hadm_id);

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.sofa2_scores_v3 IS 'SOFA2评分系统简化版本 - 使用高性能配置';

-- 显示结果统计
SELECT
    'SOFA2 V3 表创建成功！' AS status,
    COUNT(*) AS total_records,
    COUNT(DISTINCT stay_id) AS unique_stays,
    COUNT(DISTINCT subject_id) AS unique_patients,
    ROUND(AVG(sofa2_total), 2) AS avg_score,
    MIN(sofa2_total) AS min_score,
    MAX(sofa2_total) AS max_score,
    ROUND(STDDEV(sofa2_total), 2) AS score_stddev
FROM mimiciv_derived.sofa2_scores_v3;

-- 显示评分分布
SELECT
    'SOFA2评分分布' AS distribution,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM mimiciv_derived.sofa2_scores_v3), 2) AS percentage
FROM mimiciv_derived.sofa2_scores_v3
GROUP BY sofa2_total
ORDER BY sofa2_total;

SELECT '🎉 SOFA2评分表创建任务成功完成！' AS final_status;