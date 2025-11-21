-- =================================================================
-- 步骤 2: 生成各组件中间表 (UNLOGGED Tables)
-- =================================================================

-- 2.1 镇静药物 (Sedation)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_sedation AS
WITH sedation_drugs AS (
    SELECT UNNEST(ARRAY['propofol', 'dexmedetomidine', 'midazolam', 'lorazepam', 'diazepam', 'ketamine', 'clonidine', 'etomidate']) AS drug_name
),
sedation_filtered AS (
    SELECT ie.stay_id, pr.starttime, pr.stoptime
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE EXISTS (SELECT 1 FROM sedation_drugs sd WHERE LOWER(pr.drug) = sd.drug_name)
      AND pr.starttime IS NOT NULL AND pr.route IN ('IV DRIP', 'IV', 'Intravenous', 'IVPCA', 'SC', 'IM')
)
SELECT stay_id, starttime,
    CASE
        WHEN stoptime > starttime AND EXTRACT(EPOCH FROM (stoptime - starttime)) BETWEEN 3600 AND 604800 THEN stoptime
        WHEN stoptime > starttime AND EXTRACT(EPOCH FROM (stoptime - starttime)) < 3600 THEN starttime + INTERVAL '4 hours'
        WHEN stoptime > starttime AND EXTRACT(EPOCH FROM (stoptime - starttime)) > 604800 THEN starttime + INTERVAL '7 days'
        ELSE starttime + INTERVAL '24 hours'
    END AS stoptime
FROM sedation_filtered;
CREATE INDEX idx_st1_sedation ON mimiciv_derived.sofa2_stage1_sedation(stay_id, starttime, stoptime);

-- 2.2 呼吸支持时间段 (Ventilation)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_vent AS
SELECT stay_id, starttime, endtime, ventilation_status
FROM mimiciv_derived.ventilation
WHERE ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy');
CREATE INDEX idx_st1_vent ON mimiciv_derived.sofa2_stage1_vent(stay_id, starttime, endtime);

-- 2.3 SF Ratio (SpO2/FiO2) - 使用通用分组法替代 IGNORE NULLS 以防报错
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_sf AS
WITH raw_timeline AS (
    -- SpO2 (<98%)
    SELECT stay_id, charttime, valuenum AS spo2, NULL::numeric AS fio2
    FROM mimiciv_icu.chartevents WHERE itemid = 220277 AND valuenum > 0 AND valuenum < 98
    UNION ALL
    -- FiO2 (ChartEvents, 修复单位)
    SELECT stay_id, charttime, NULL::numeric AS spo2, CASE WHEN valuenum <= 1.0 THEN valuenum * 100.0 ELSE valuenum END AS fio2
    FROM mimiciv_icu.chartevents WHERE itemid = 223835 AND valuenum > 0
    UNION ALL
    -- FiO2 (Blood Gas, 修复 stay_id)
    SELECT ie.stay_id, bg.charttime, NULL::numeric AS spo2, bg.fio2
    FROM mimiciv_derived.bg bg
    JOIN mimiciv_icu.icustays ie ON bg.subject_id = ie.subject_id 
        AND bg.charttime BETWEEN ie.intime - INTERVAL '6 HOURS' AND ie.outtime
    WHERE bg.fio2 IS NOT NULL
),
timeline_grouped AS (
    SELECT stay_id, charttime, spo2, fio2,
           COUNT(fio2) OVER (PARTITION BY stay_id ORDER BY charttime) as fio2_grp
    FROM raw_timeline
),
imputed AS (
    SELECT stay_id, charttime, spo2,
           FIRST_VALUE(fio2) OVER (PARTITION BY stay_id, fio2_grp ORDER BY charttime) AS fio2_val
    FROM timeline_grouped
)
SELECT stay_id, charttime, spo2 / (fio2_val / 100.0) AS sf_ratio
FROM imputed WHERE spo2 IS NOT NULL AND fio2_val IS NOT NULL;
CREATE INDEX idx_st1_sf ON mimiciv_derived.sofa2_stage1_sf(stay_id, charttime);

-- 2.4 机械循环支持 (Mech Support)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_mech AS
SELECT ce.stay_id, ce.charttime,
    CASE WHEN ce.itemid IN (224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276, 229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273, 228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260) THEN 1 ELSE 0 END AS is_ecmo,
    CASE WHEN ce.itemid IN (224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986, 225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355, 225742, 228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671, 228171, 228172, 228167, 228170, 224314, 224318, 229898, 220128, 220125, 229899, 229900, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 228223, 228226, 228219, 228225, 228222, 228224, 228203, 228227, 229263, 229255, 229259, 229257, 229265, 229251, 229253, 229261, 229560, 229559, 228187, 228867) THEN 1 ELSE 0 END AS is_other_mech
FROM mimiciv_icu.chartevents ce
WHERE ce.itemid IN (224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276, 229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273, 228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986, 225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355, 225742, 228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671, 228171, 228172, 228167, 228170, 224314, 224318, 229898, 220128, 220125, 229899, 229900, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 228223, 228226, 228219, 228225, 228222, 228224, 228203, 228227, 229263, 229255, 229259, 229257, 229265, 229251, 229253, 229261, 229560, 229559, 228187, 228867);
CREATE INDEX idx_st1_mech ON mimiciv_derived.sofa2_stage1_mech(stay_id, charttime);

-- 2.5 胆红素 (Bilirubin)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_bilirubin AS
SELECT stay.stay_id, enz.charttime, enz.bilirubin_total
FROM mimiciv_icu.icustays stay
JOIN mimiciv_derived.enzyme enz ON stay.hadm_id = enz.hadm_id
WHERE enz.bilirubin_total IS NOT NULL AND enz.charttime >= stay.intime - INTERVAL '6 HOURS' AND enz.charttime <= stay.outtime;
CREATE INDEX idx_st1_bili ON mimiciv_derived.sofa2_stage1_bilirubin(stay_id, charttime);

-- 2.6 肾脏 Lab (Kidney Labs)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_kidney_labs AS
SELECT stay.stay_id, bg.charttime, chem.creatinine, bg.potassium, bg.ph, bg.bicarbonate
FROM mimiciv_icu.icustays stay
LEFT JOIN mimiciv_derived.chemistry chem ON stay.hadm_id = chem.hadm_id AND chem.charttime BETWEEN stay.intime - INTERVAL '6 HOURS' AND stay.outtime
LEFT JOIN mimiciv_derived.bg bg ON stay.subject_id = bg.subject_id AND bg.charttime BETWEEN stay.intime - INTERVAL '6 HOURS' AND stay.outtime AND bg.specimen = 'ART.'
WHERE chem.creatinine IS NOT NULL OR bg.ph IS NOT NULL;
CREATE INDEX idx_st1_klabs ON mimiciv_derived.sofa2_stage1_kidney_labs(stay_id, charttime);

-- 2.7 RRT 疗程 (RRT Periods - 72h gap logic)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_rrt AS
WITH rrt_raw AS (SELECT stay_id, charttime FROM mimiciv_derived.rrt WHERE dialysis_present = 1),
rrt_groups AS (SELECT stay_id, charttime, CASE WHEN EXTRACT(EPOCH FROM (charttime - LAG(charttime) OVER (PARTITION BY stay_id ORDER BY charttime)))/3600 > 72 THEN 1 ELSE 0 END AS is_new_episode FROM rrt_raw),
rrt_episodes AS (SELECT stay_id, charttime, SUM(is_new_episode) OVER (PARTITION BY stay_id ORDER BY charttime) AS episode_id FROM rrt_groups)
SELECT stay_id, MIN(charttime) AS start_time, MAX(charttime) AS end_time FROM rrt_episodes GROUP BY stay_id, episode_id;
CREATE INDEX idx_st1_rrt ON mimiciv_derived.sofa2_stage1_rrt(stay_id, start_time, end_time);

-- 2.8 尿量滑动窗口 (Urine Windows)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_urine AS
WITH weight_data AS (SELECT stay_id, AVG(weight) as weight FROM mimiciv_derived.weight_durations WHERE weight > 0 GROUP BY stay_id),
uo_hourly AS (
    SELECT ih.stay_id, ih.hr, SUM(uo.urineoutput) AS uo_hourly_vol, MAX(wd.weight) as patient_weight
    FROM mimiciv_derived.icustay_hourly ih
    JOIN weight_data wd ON ih.stay_id = wd.stay_id
    LEFT JOIN mimiciv_derived.urine_output uo ON ih.stay_id = uo.stay_id AND uo.charttime >= ih.endtime - INTERVAL '1 HOUR' AND uo.charttime < ih.endtime
    GROUP BY ih.stay_id, ih.hr
)
SELECT stay_id, hr, patient_weight,
    SUM(uo_hourly_vol) OVER w6 AS uo_sum_6h, COUNT(uo_hourly_vol) OVER w6 AS cnt_6h,
    SUM(uo_hourly_vol) OVER w12 AS uo_sum_12h, COUNT(uo_hourly_vol) OVER w12 AS cnt_12h,
    SUM(uo_hourly_vol) OVER w24 AS uo_sum_24h, COUNT(uo_hourly_vol) OVER w24 AS cnt_24h
FROM uo_hourly
WINDOW 
    w6 AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 5 PRECEDING AND CURRENT ROW),
    w12 AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 11 PRECEDING AND CURRENT ROW),
    w24 AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW);
CREATE INDEX idx_st1_urine ON mimiciv_derived.sofa2_stage1_urine(stay_id, hr);

-- 2.9 血小板 (Platelets)
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_platelets AS
SELECT stay.stay_id, cbc.charttime, cbc.platelet
FROM mimiciv_icu.icustays stay
JOIN mimiciv_derived.complete_blood_count cbc ON stay.hadm_id = cbc.hadm_id
WHERE cbc.platelet IS NOT NULL AND cbc.charttime >= stay.intime - INTERVAL '6 HOURS' AND cbc.charttime <= stay.outtime;
CREATE INDEX idx_st1_plt ON mimiciv_derived.sofa2_stage1_platelets(stay_id, charttime);

-- -----------------------------------------------------------------
-- 10. 神经系统 GCS (Brain) - 预计算优化版
-- 逻辑：提前计算好每个时间段的有效 GCS 分数，避免主查询逐行扫描
-- -----------------------------------------------------------------
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_brain CASCADE;

CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_brain AS
WITH gcs_base AS (
    -- 1. 标记每个 GCS 记录是否处于镇静状态
    SELECT 
        g.stay_id, 
        g.charttime, 
        g.gcs,
        -- 关联之前生成的镇静表，判断当前时刻是否有镇静
        CASE WHEN s.stay_id IS NOT NULL THEN 1 ELSE 0 END AS is_sedated
    FROM mimiciv_derived.gcs g
    LEFT JOIN mimiciv_derived.sofa2_stage1_sedation s 
      ON g.stay_id = s.stay_id 
      AND g.charttime >= s.starttime 
      AND g.charttime <= s.stoptime
),
gcs_locf AS (
    -- 2. 寻找"最近一次未镇静的 GCS" (LOCF逻辑)
    SELECT 
        stay_id, charttime, gcs, is_sedated,
        -- 技巧：生成分组ID。只有遇到未镇静的记录，组号才+1
        COUNT(CASE WHEN is_sedated = 0 THEN 1 END) OVER (PARTITION BY stay_id ORDER BY charttime) as grp
    FROM gcs_base
),
gcs_resolved AS (
    -- 3. 确定有效 GCS 值
    SELECT 
        stay_id, charttime,
        -- 如果当前镇静，取当前组的第一条(即最近一次未镇静值)；若无回溯值，则被迫用当前值
        CASE 
            WHEN is_sedated = 1 THEN 
                COALESCE(FIRST_VALUE(gcs) OVER (PARTITION BY stay_id, grp ORDER BY charttime), gcs)
            ELSE gcs 
        END as effective_gcs
    FROM gcs_locf
),
gcs_scored AS (
    -- 4. 将 GCS 值转换为 SOFA 分数 (0-4分)
    SELECT 
        stay_id, charttime,
        CASE 
            WHEN effective_gcs <= 5 THEN 4 
            WHEN effective_gcs <= 8 THEN 3 
            WHEN effective_gcs <= 12 THEN 2 
            WHEN effective_gcs <= 14 THEN 1 
            ELSE 0 
        END as brain_score_raw
    FROM gcs_resolved
)
-- 5. 生成时间区间表 (从当前记录开始，持续到下一条记录出现)
SELECT 
    stay_id, 
    charttime AS starttime,
    -- 下一条记录的时间作为当前分数的结束时间
    LEAD(charttime, 1, 'infinity'::timestamp) OVER (PARTITION BY stay_id ORDER BY charttime) AS endtime,
    brain_score_raw
FROM gcs_scored;

-- 建立区间索引 (极速 Range Join 的关键)
CREATE INDEX idx_st1_brain ON mimiciv_derived.sofa2_stage1_brain(stay_id, starttime, endtime);
ANALYZE mimiciv_derived.sofa2_stage1_brain;