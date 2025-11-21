-- =================================================================
-- SOFA-2 评分系统 - 最终完美修正版 (Fixed BG Schema Issue)
-- =================================================================

-- 0. 性能参数配置
SET work_mem = '2047MB';
SET maintenance_work_mem = '2047MB';
SET max_parallel_workers = 24;
SET max_parallel_workers_per_gather = 12;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
SET enable_parallel_hash = on;
SET jit = off;

-- =================================================================
-- 第一阶段：创建所有临时表 (Temp Tables)
-- =================================================================

-- 清理旧表
DROP TABLE IF EXISTS temp_sedation_hourly CASCADE;
DROP TABLE IF EXISTS temp_vent_periods CASCADE;
DROP TABLE IF EXISTS temp_sf_ratios CASCADE;
DROP TABLE IF EXISTS temp_mech_support CASCADE;
DROP TABLE IF EXISTS temp_bilirubin CASCADE;
DROP TABLE IF EXISTS temp_kidney_labs CASCADE;
DROP TABLE IF EXISTS temp_rrt_periods CASCADE;
DROP TABLE IF EXISTS temp_urine_windows CASCADE;
DROP TABLE IF EXISTS temp_platelets CASCADE;

-- -----------------------------------------------------------------
-- 1. 镇静药物 (Sedation)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_sedation_hourly AS
WITH co AS (
    SELECT ih.stay_id, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
),
sedation_drugs AS (
    SELECT UNNEST(ARRAY['propofol', 'dexmedetomidine', 'midazolam', 'lorazepam', 'diazepam', 'ketamine', 'clonidine', 'etomidate']) AS drug_name
),
sedation_filtered AS (
    SELECT ie.stay_id, pr.starttime, pr.stoptime, 1 AS is_sedation_drug
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE EXISTS (SELECT 1 FROM sedation_drugs sd WHERE LOWER(pr.drug) = sd.drug_name)
      AND pr.starttime IS NOT NULL AND pr.route IN ('IV DRIP', 'IV', 'Intravenous', 'IVPCA', 'SC', 'IM')
),
infusion_periods AS (
    SELECT stay_id, starttime,
        CASE
            WHEN stoptime > starttime AND EXTRACT(EPOCH FROM (stoptime - starttime)) BETWEEN 3600 AND 604800 THEN stoptime
            WHEN stoptime > starttime AND EXTRACT(EPOCH FROM (stoptime - starttime)) < 3600 THEN starttime + INTERVAL '4 hours'
            WHEN stoptime > starttime AND EXTRACT(EPOCH FROM (stoptime - starttime)) > 604800 THEN starttime + INTERVAL '7 days'
            ELSE starttime + INTERVAL '24 hours'
        END AS stoptime,
        is_sedation_drug
    FROM sedation_filtered
)
SELECT co.stay_id, co.endtime, MAX(1) AS has_sedation_infusion
FROM co
JOIN infusion_periods sp ON co.stay_id = sp.stay_id AND sp.starttime <= co.endtime AND sp.stoptime > co.starttime
GROUP BY co.stay_id, co.endtime;

CREATE INDEX idx_temp_sedation ON temp_sedation_hourly (stay_id, endtime);
ANALYZE temp_sedation_hourly;

-- -----------------------------------------------------------------
-- 2. 呼吸支持时间段 (Ventilation)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_vent_periods AS
SELECT stay_id, starttime, endtime, ventilation_status
FROM mimiciv_derived.ventilation
WHERE ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy');

CREATE INDEX idx_temp_vent ON temp_vent_periods (stay_id, starttime, endtime);
ANALYZE temp_vent_periods;

-- -----------------------------------------------------------------
-- 3. SF Ratio 计算 (修复: 关联ICUStays获取stay_id + 通用LOCF)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_sf_ratios AS
WITH raw_timeline AS (
    -- A. 获取 SpO2
    SELECT stay_id, charttime, valuenum AS spo2, NULL::numeric AS fio2
    FROM mimiciv_icu.chartevents WHERE itemid = 220277 AND valuenum > 0 AND valuenum < 98
    
    UNION ALL
    
    -- B. 获取 FiO2 (ChartEvents)
    SELECT stay_id, charttime, NULL::numeric AS spo2, CASE WHEN valuenum <= 1.0 THEN valuenum * 100.0 ELSE valuenum END AS fio2
    FROM mimiciv_icu.chartevents WHERE itemid = 223835 AND valuenum > 0
    
    UNION ALL
    
    -- C. 获取 FiO2 (Blood Gas) - 关键修复: 关联获取 stay_id
    SELECT ie.stay_id, bg.charttime, NULL::numeric AS spo2, bg.fio2
    FROM mimiciv_derived.bg bg
    JOIN mimiciv_icu.icustays ie ON bg.subject_id = ie.subject_id 
        AND bg.charttime BETWEEN ie.intime - INTERVAL '6 HOURS' AND ie.outtime
    WHERE bg.fio2 IS NOT NULL
),
timeline_grouped AS (
    -- 兼容旧版PG的分组填充法
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

CREATE INDEX idx_temp_sf ON temp_sf_ratios (stay_id, charttime);
ANALYZE temp_sf_ratios;

-- -----------------------------------------------------------------
-- 4. 机械循环支持 (Mechanical Support)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_mech_support AS
SELECT ce.stay_id, ce.charttime,
    CASE WHEN ce.itemid IN (224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276, 229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273, 228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260) THEN 1 ELSE 0 END AS is_ecmo,
    CASE WHEN ce.itemid IN (224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986, 225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355, 225742, 228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671, 228171, 228172, 228167, 228170, 224314, 224318, 229898, 220128, 220125, 229899, 229900, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 228223, 228226, 228219, 228225, 228222, 228224, 228203, 228227, 229263, 229255, 229259, 229257, 229265, 229251, 229253, 229261, 229560, 229559, 228187, 228867) THEN 1 ELSE 0 END AS is_other_mech
FROM mimiciv_icu.chartevents ce
WHERE ce.itemid IN (224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276, 229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273, 228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986, 225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355, 225742, 228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671, 228171, 228172, 228167, 228170, 224314, 224318, 229898, 220128, 220125, 229899, 229900, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 228223, 228226, 228219, 228225, 228222, 228224, 228203, 228227, 229263, 229255, 229259, 229257, 229265, 229251, 229253, 229261, 229560, 229559, 228187, 228867);

CREATE INDEX idx_temp_mech ON temp_mech_support (stay_id, charttime);
ANALYZE temp_mech_support;

-- -----------------------------------------------------------------
-- 5. 胆红素 (Bilirubin)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_bilirubin AS
SELECT stay.stay_id, enz.charttime, enz.bilirubin_total
FROM mimiciv_icu.icustays stay
JOIN mimiciv_derived.enzyme enz ON stay.hadm_id = enz.hadm_id
WHERE enz.bilirubin_total IS NOT NULL AND enz.charttime >= stay.intime - INTERVAL '6 HOURS' AND enz.charttime <= stay.outtime;

CREATE INDEX idx_temp_bili ON temp_bilirubin (stay_id, charttime);
ANALYZE temp_bilirubin;

-- -----------------------------------------------------------------
-- 6. 肾脏 Lab (Kidney Labs)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_kidney_labs AS
SELECT stay.stay_id, bg.charttime, chem.creatinine, bg.potassium, bg.ph, bg.bicarbonate
FROM mimiciv_icu.icustays stay
LEFT JOIN mimiciv_derived.chemistry chem ON stay.hadm_id = chem.hadm_id AND chem.charttime BETWEEN stay.intime - INTERVAL '6 HOURS' AND stay.outtime
LEFT JOIN mimiciv_derived.bg bg ON stay.subject_id = bg.subject_id AND bg.charttime BETWEEN stay.intime - INTERVAL '6 HOURS' AND stay.outtime AND bg.specimen = 'ART.'
WHERE chem.creatinine IS NOT NULL OR bg.ph IS NOT NULL;

CREATE INDEX idx_temp_klabs ON temp_kidney_labs (stay_id, charttime);
ANALYZE temp_kidney_labs;

-- -----------------------------------------------------------------
-- 7. RRT 疗程 (Intermittent Periods)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_rrt_periods AS
WITH rrt_raw AS (SELECT stay_id, charttime FROM mimiciv_derived.rrt WHERE dialysis_present = 1),
rrt_groups AS (SELECT stay_id, charttime, CASE WHEN EXTRACT(EPOCH FROM (charttime - LAG(charttime) OVER (PARTITION BY stay_id ORDER BY charttime)))/3600 > 72 THEN 1 ELSE 0 END AS is_new_episode FROM rrt_raw),
rrt_episodes AS (SELECT stay_id, charttime, SUM(is_new_episode) OVER (PARTITION BY stay_id ORDER BY charttime) AS episode_id FROM rrt_groups)
SELECT stay_id, MIN(charttime) AS start_time, MAX(charttime) AS end_time FROM rrt_episodes GROUP BY stay_id, episode_id;

CREATE INDEX idx_temp_rrt ON temp_rrt_periods (stay_id, start_time, end_time);
ANALYZE temp_rrt_periods;

-- -----------------------------------------------------------------
-- 8. 尿量滑动窗口 (Urine Output)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_urine_windows AS
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

CREATE INDEX idx_temp_urine ON temp_urine_windows (stay_id, hr);
ANALYZE temp_urine_windows;

-- -----------------------------------------------------------------
-- 9. 血小板 (Platelets)
-- -----------------------------------------------------------------
CREATE TEMP TABLE temp_platelets AS
SELECT stay.stay_id, cbc.charttime, cbc.platelet
FROM mimiciv_icu.icustays stay
JOIN mimiciv_derived.complete_blood_count cbc ON stay.hadm_id = cbc.hadm_id
WHERE cbc.platelet IS NOT NULL AND cbc.charttime >= stay.intime - INTERVAL '6 HOURS' AND cbc.charttime <= stay.outtime;

CREATE INDEX idx_temp_plt ON temp_platelets (stay_id, charttime);
ANALYZE temp_platelets;


-- =================================================================
-- 第二阶段：主查询聚合 (修复 Column Name Error)
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores CASCADE;

CREATE TABLE mimiciv_derived.sofa2_scores AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
),

-- 1. 谵妄药物状态
delirium_status AS (
    SELECT co.stay_id, co.hr, MAX(1) AS on_delirium_med
    FROM co
    JOIN mimiciv_hosp.prescriptions pr ON co.hadm_id = pr.hadm_id
    WHERE LOWER(pr.drug) IN ('haloperidol','quetiapine','quetiapine fumarate','olanzapine','olanzapine (disintegrating tablet)','risperidone','risperidone (disintegrating tablet)','ziprasidone','ziprasidone hydrochloride','clozapine','aripiprazole')
      AND pr.starttime <= co.endtime AND COALESCE(pr.stoptime, pr.starttime + INTERVAL '24 hours') >= co.starttime
    GROUP BY co.stay_id, co.hr
),

-- 2. GCS (Brain)
gcs_calc AS (
    SELECT gcs.stay_id, gcs.charttime, CASE WHEN gcs.gcs < 3 THEN 3 WHEN gcs.gcs > 15 THEN 15 ELSE gcs.gcs END AS gcs,
           COALESCE(sh.has_sedation_infusion, 0) AS is_sedated
    FROM mimiciv_derived.gcs gcs
    LEFT JOIN temp_sedation_hourly sh ON gcs.stay_id = sh.stay_id AND gcs.charttime <= sh.endtime
),
brain_sofa AS (
    SELECT co.stay_id, co.hr,
        GREATEST(
            CASE WHEN gcs_vals.gcs IS NULL THEN 0
                 WHEN gcs_vals.gcs <= 5 THEN 4 WHEN gcs_vals.gcs <= 8 THEN 3 WHEN gcs_vals.gcs <= 12 THEN 2 WHEN gcs_vals.gcs <= 14 THEN 1 ELSE 0 END,
            CASE WHEN ds.on_delirium_med = 1 THEN 1 ELSE 0 END
        ) AS brain
    FROM co
    LEFT JOIN LATERAL (
        SELECT gcs.gcs FROM gcs_calc gcs WHERE gcs.stay_id = co.stay_id AND gcs.charttime <= co.endtime
        ORDER BY CASE WHEN gcs.charttime >= co.starttime AND gcs.is_sedated = 0 THEN 0 ELSE 1 END, gcs.is_sedated, gcs.charttime DESC LIMIT 1
    ) gcs_vals ON TRUE
    LEFT JOIN delirium_status ds ON co.stay_id = ds.stay_id AND co.hr = ds.hr
),

-- 3. Respiratory (修复: 列名修正 pf_ratio -> pao2fio2ratio)
resp_sofa AS (
    SELECT co.stay_id, co.hr,
        CASE
            WHEN COALESCE(ecmo.is_ecmo, 0) = 1 THEN 4
            -- 修正点：使用正确的列名 pao2fio2ratio
            WHEN pf.pao2fio2ratio IS NOT NULL THEN
                CASE WHEN pf.pao2fio2ratio <= 75 AND vent.ventilation_status IS NOT NULL THEN 4
                     WHEN pf.pao2fio2ratio <= 150 AND vent.ventilation_status IS NOT NULL THEN 3
                     WHEN pf.pao2fio2ratio <= 225 THEN 2
                     WHEN pf.pao2fio2ratio <= 300 THEN 1 ELSE 0 END
            WHEN sf.sf_ratio IS NOT NULL THEN
                CASE WHEN sf.sf_ratio <= 120 AND vent.ventilation_status IS NOT NULL THEN 4
                     WHEN sf.sf_ratio <= 200 AND vent.ventilation_status IS NOT NULL THEN 3
                     WHEN sf.sf_ratio <= 250 THEN 2
                     WHEN sf.sf_ratio <= 300 THEN 1 ELSE 0 END
            ELSE 0
        END AS respiratory
    FROM co
    LEFT JOIN temp_vent_periods vent ON co.stay_id = vent.stay_id AND co.endtime > vent.starttime AND co.starttime < vent.endtime
    LEFT JOIN temp_mech_support ecmo ON co.stay_id = ecmo.stay_id AND ecmo.charttime BETWEEN co.starttime AND co.endtime AND ecmo.is_ecmo = 1
    -- 关联 BG 表
    LEFT JOIN mimiciv_derived.bg pf 
        ON co.subject_id = pf.subject_id 
        AND pf.charttime BETWEEN co.starttime AND co.endtime
        AND pf.specimen = 'ART.'
    LEFT JOIN temp_sf_ratios sf ON co.stay_id = sf.stay_id AND sf.charttime BETWEEN co.starttime AND co.endtime
    -- 修正 Group By 中的列名
    GROUP BY co.stay_id, co.hr, ecmo.is_ecmo, vent.ventilation_status, pf.pao2fio2ratio, sf.sf_ratio
),
resp_sofa_agg AS (
    SELECT stay_id, hr, MAX(respiratory) as respiratory FROM resp_sofa GROUP BY stay_id, hr
),

-- 4. Cardiovascular
cv_data AS (
    SELECT co.stay_id, co.hr,
        MAX(mech.is_ecmo) as has_ecmo, MAX(mech.is_other_mech) as has_other_mech, MIN(vs.mbp) as mbp_min,
        MAX(va.norepinephrine) as rate_nor, MAX(va.epinephrine) as rate_epi, MAX(va.dopamine) as rate_dop,
        MAX(va.dobutamine) as rate_dob, MAX(va.vasopressin) as rate_vas, MAX(va.phenylephrine) as rate_phe, MAX(va.milrinone) as rate_mil
    FROM co
    LEFT JOIN temp_mech_support mech ON co.stay_id = mech.stay_id AND mech.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN mimiciv_derived.vitalsign vs ON co.stay_id = vs.stay_id AND vs.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN mimiciv_derived.vasoactive_agent va ON co.stay_id = va.stay_id AND va.starttime < co.endtime AND COALESCE(va.endtime, co.endtime) > co.starttime
    GROUP BY co.stay_id, co.hr
),
cv_sofa AS (
    SELECT stay_id, hr,
        CASE
            WHEN COALESCE(has_ecmo, 0)=1 OR COALESCE(has_other_mech, 0)=1 THEN 4
            WHEN (COALESCE(rate_nor,0)/2.0 + COALESCE(rate_epi,0)) > 0.4 THEN 4
            WHEN (COALESCE(rate_nor,0)/2.0 + COALESCE(rate_epi,0)) > 0.2 AND other_drug=1 THEN 4
            WHEN dop_score=4 THEN 4
            WHEN (COALESCE(rate_nor,0)/2.0 + COALESCE(rate_epi,0)) > 0.2 THEN 3
            WHEN (COALESCE(rate_nor,0)/2.0 + COALESCE(rate_epi,0)) > 0 AND other_drug=1 THEN 3
            WHEN dop_score=3 THEN 3
            WHEN (COALESCE(rate_nor,0)/2.0 + COALESCE(rate_epi,0)) > 0 THEN 2
            WHEN other_drug=1 THEN 2
            WHEN dop_score=2 THEN 2
            WHEN COALESCE(mbp_min, 70) < 40 THEN 4
            WHEN COALESCE(mbp_min, 70) < 50 THEN 3
            WHEN COALESCE(mbp_min, 70) < 60 THEN 2
            WHEN COALESCE(mbp_min, 70) < 70 THEN 1
            ELSE 0
        END AS cardiovascular
    FROM (
        SELECT *,
            CASE WHEN rate_dop > 40 THEN 4 WHEN rate_dop > 20 THEN 3 WHEN rate_dop > 0 THEN 2 ELSE 0 END as dop_score,
            CASE WHEN (COALESCE(rate_dob,0)>0 OR COALESCE(rate_vas,0)>0 OR COALESCE(rate_phe,0)>0 OR COALESCE(rate_mil,0)>0) THEN 1 ELSE 0 END as other_drug
        FROM cv_data
    ) x
),

-- 5. Liver
liver_sofa AS (
    SELECT co.stay_id, co.hr,
        CASE WHEN MAX(b.bilirubin_total) > 12.0 THEN 4 WHEN MAX(b.bilirubin_total) > 6.0 THEN 3 WHEN MAX(b.bilirubin_total) > 3.0 THEN 2 WHEN MAX(b.bilirubin_total) > 1.2 THEN 1 ELSE 0 END AS liver
    FROM co
    LEFT JOIN temp_bilirubin b ON co.stay_id = b.stay_id AND b.charttime BETWEEN co.starttime AND co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 6. Kidney
kidney_sofa AS (
    SELECT co.stay_id, co.hr,
        CASE
            WHEN MAX(rrt.start_time) IS NOT NULL THEN 4
            WHEN (MAX(l.creatinine) > 1.2 OR (MAX(u.cnt_6h)=6 AND MAX(u.uo_sum_6h)/(MAX(u.patient_weight)*6.0) < 0.3)) AND (MAX(l.potassium)>=6.0 OR (MIN(l.ph)<=7.2 AND MIN(l.bicarbonate)<=12)) THEN 4
            WHEN MAX(l.creatinine) > 3.5 THEN 3
            WHEN MAX(u.cnt_24h)=24 AND MAX(u.uo_sum_24h)/(MAX(u.patient_weight)*24.0) < 0.3 THEN 3
            WHEN MAX(u.cnt_12h)=12 AND MAX(u.uo_sum_12h) < 5.0 THEN 3
            WHEN MAX(l.creatinine) > 2.0 THEN 2
            WHEN MAX(u.cnt_12h)=12 AND MAX(u.uo_sum_12h)/(MAX(u.patient_weight)*12.0) < 0.5 THEN 2
            WHEN MAX(l.creatinine) > 1.2 THEN 1
            WHEN MAX(u.cnt_6h)=6 AND MAX(u.uo_sum_6h)/(MAX(u.patient_weight)*6.0) < 0.5 THEN 1
            ELSE 0
        END AS kidney
    FROM co
    LEFT JOIN temp_kidney_labs l ON co.stay_id = l.stay_id AND l.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN temp_rrt_periods rrt ON co.stay_id = rrt.stay_id AND co.endtime > rrt.start_time AND co.starttime < rrt.end_time
    LEFT JOIN temp_urine_windows u ON co.stay_id = u.stay_id AND u.hr = co.hr
    GROUP BY co.stay_id, co.hr
),

-- 7. Hemostasis
hemo_sofa AS (
    SELECT co.stay_id, co.hr,
        CASE WHEN MIN(p.platelet) <= 50 THEN 4 WHEN MIN(p.platelet) <= 80 THEN 3 WHEN MIN(p.platelet) <= 100 THEN 2 WHEN MIN(p.platelet) <= 150 THEN 1 ELSE 0 END AS hemostasis
    FROM co
    LEFT JOIN temp_platelets p ON co.stay_id = p.stay_id AND p.charttime BETWEEN co.starttime AND co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 8. 最终整合与窗口聚合
final_scores AS (
    SELECT
        co.stay_id, co.hadm_id, co.subject_id, co.hr, co.starttime, co.endtime,
        COALESCE(MAX(br.brain) OVER w, 0) AS brain,
        COALESCE(MAX(rs.respiratory) OVER w, 0) AS respiratory,
        COALESCE(MAX(cv.cardiovascular) OVER w, 0) AS cardiovascular,
        COALESCE(MAX(lv.liver) OVER w, 0) AS liver,
        COALESCE(MAX(kd.kidney) OVER w, 0) AS kidney,
        COALESCE(MAX(hm.hemostasis) OVER w, 0) AS hemostasis
    FROM co
    LEFT JOIN brain_sofa br ON co.stay_id = br.stay_id AND co.hr = br.hr
    LEFT JOIN resp_sofa_agg rs ON co.stay_id = rs.stay_id AND co.hr = rs.hr
    LEFT JOIN cv_sofa cv ON co.stay_id = cv.stay_id AND co.hr = cv.hr
    LEFT JOIN liver_sofa lv ON co.stay_id = lv.stay_id AND co.hr = lv.hr
    LEFT JOIN kidney_sofa kd ON co.stay_id = kd.stay_id AND co.hr = kd.hr
    LEFT JOIN hemo_sofa hm ON co.stay_id = hm.stay_id AND co.hr = hm.hr
    WINDOW w AS (PARTITION BY co.stay_id ORDER BY co.hr ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING)
)

-- 9. 输出
SELECT *, (brain + respiratory + cardiovascular + liver + kidney + hemostasis) as sofa2_total
FROM final_scores
WHERE hr >= 0;

-- 添加索引和注释
ALTER TABLE mimiciv_derived.sofa2_scores ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;
CREATE INDEX idx_sofa2_stay ON mimiciv_derived.sofa2_scores(stay_id);
COMMENT ON TABLE mimiciv_derived.sofa2_scores IS 'SOFA-2 Scores (JAMA 2025) - Final Corrected Version';