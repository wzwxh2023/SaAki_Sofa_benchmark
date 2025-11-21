-- =================================================================
-- 步骤 3: 计算每小时原始评分 (Raw Hourly Scores) - 极速优化版
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_hourly_raw CASCADE;

CREATE TABLE mimiciv_derived.sofa2_hourly_raw AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
),
-- 1. 谵妄状态
delirium_status AS (
    SELECT co.stay_id, co.hr, MAX(1) AS on_delirium_med
    FROM co
    JOIN mimiciv_hosp.prescriptions pr ON co.hadm_id = pr.hadm_id
    WHERE LOWER(pr.drug) IN ('haloperidol','quetiapine','quetiapine fumarate','olanzapine','olanzapine (disintegrating tablet)','risperidone','risperidone (disintegrating tablet)','ziprasidone','ziprasidone hydrochloride','clozapine','aripiprazole')
      AND pr.starttime <= co.endtime AND COALESCE(pr.stoptime, pr.starttime + INTERVAL '24 hours') >= co.starttime
    GROUP BY co.stay_id, co.hr
),

-- 2. GCS (Brain) - ★★★ 关键修改：使用预计算表进行极速连接 ★★★
brain_sofa AS (
    SELECT 
        co.stay_id, 
        co.hr,
        GREATEST(
            -- 来源1: 预计算好的 GCS (Range Join)
            COALESCE(bg.brain_score_raw, 0),
            -- 来源2: 谵妄药物
            CASE WHEN ds.on_delirium_med = 1 THEN 1 ELSE 0 END
        ) AS brain
    FROM co
    -- 使用 Step 2 生成的物理表，避免逐行计算
    LEFT JOIN mimiciv_derived.sofa2_stage1_brain bg 
        ON co.stay_id = bg.stay_id 
        AND co.endtime > bg.starttime 
        AND co.endtime <= bg.endtime
    LEFT JOIN delirium_status ds ON co.stay_id = ds.stay_id AND co.hr = ds.hr
),

-- 3. Respiratory
resp_sofa AS (
    SELECT co.stay_id, co.hr, MAX(
        CASE
            WHEN COALESCE(ecmo.is_ecmo, 0) = 1 THEN 4
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
        END) AS respiratory
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_vent vent ON co.stay_id = vent.stay_id AND co.endtime > vent.starttime AND co.starttime < vent.endtime
    LEFT JOIN mimiciv_derived.sofa2_stage1_mech ecmo ON co.stay_id = ecmo.stay_id AND ecmo.charttime BETWEEN co.starttime AND co.endtime AND ecmo.is_ecmo = 1
    LEFT JOIN mimiciv_derived.bg pf ON co.subject_id = pf.subject_id AND pf.charttime BETWEEN co.starttime AND co.endtime AND pf.specimen = 'ART.'
    LEFT JOIN mimiciv_derived.sofa2_stage1_sf sf ON co.stay_id = sf.stay_id AND sf.charttime BETWEEN co.starttime AND co.endtime
    GROUP BY co.stay_id, co.hr
),
-- 4. Cardiovascular
cv_data AS (
    SELECT co.stay_id, co.hr,
        MAX(mech.is_ecmo) as has_ecmo, MAX(mech.is_other_mech) as has_other_mech, MIN(vs.mbp) as mbp_min,
        MAX(va.norepinephrine) as rate_nor, MAX(va.epinephrine) as rate_epi, MAX(va.dopamine) as rate_dop,
        MAX(va.dobutamine) as rate_dob, MAX(va.vasopressin) as rate_vas, MAX(va.phenylephrine) as rate_phe, MAX(va.milrinone) as rate_mil
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_mech mech ON co.stay_id = mech.stay_id AND mech.charttime BETWEEN co.starttime AND co.endtime
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
    LEFT JOIN mimiciv_derived.sofa2_stage1_bilirubin b ON co.stay_id = b.stay_id AND b.charttime BETWEEN co.starttime AND co.endtime
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
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs l ON co.stay_id = l.stay_id AND l.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rrt ON co.stay_id = rrt.stay_id AND co.endtime > rrt.start_time AND co.starttime < rrt.end_time
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON co.stay_id = u.stay_id AND u.hr = co.hr
    GROUP BY co.stay_id, co.hr
),
-- 7. Hemostasis
hemo_sofa AS (
    SELECT co.stay_id, co.hr,
        CASE WHEN MIN(p.platelet) <= 50 THEN 4 WHEN MIN(p.platelet) <= 80 THEN 3 WHEN MIN(p.platelet) <= 100 THEN 2 WHEN MIN(p.platelet) <= 150 THEN 1 ELSE 0 END AS hemostasis
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_platelets p ON co.stay_id = p.stay_id AND p.charttime BETWEEN co.starttime AND co.endtime
    GROUP BY co.stay_id, co.hr
)
-- 输出每小时原始分
SELECT
    co.stay_id, co.hadm_id, co.subject_id, co.hr, co.starttime, co.endtime,
    COALESCE(br.brain, 0) AS brain_score,
    COALESCE(rs.respiratory, 0) AS respiratory_score,
    COALESCE(cv.cardiovascular, 0) AS cardiovascular_score,
    COALESCE(lv.liver, 0) AS liver_score,
    COALESCE(kd.kidney, 0) AS kidney_score,
    COALESCE(hm.hemostasis, 0) AS hemostasis_score
FROM co
LEFT JOIN brain_sofa br ON co.stay_id = br.stay_id AND co.hr = br.hr
LEFT JOIN resp_sofa rs ON co.stay_id = rs.stay_id AND co.hr = rs.hr
LEFT JOIN cv_sofa cv ON co.stay_id = cv.stay_id AND co.hr = cv.hr
LEFT JOIN liver_sofa lv ON co.stay_id = lv.stay_id AND co.hr = lv.hr
LEFT JOIN kidney_sofa kd ON co.stay_id = kd.stay_id AND co.hr = kd.hr
LEFT JOIN hemo_sofa hm ON co.stay_id = hm.stay_id AND co.hr = hm.hr;

-- 建立索引
CREATE INDEX idx_sofa2_raw_calc ON mimiciv_derived.sofa2_hourly_raw(stay_id, hr);
ANALYZE mimiciv_derived.sofa2_hourly_raw;