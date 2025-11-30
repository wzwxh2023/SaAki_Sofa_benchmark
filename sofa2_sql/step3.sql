-- =================================================================
-- 步骤 3: 计算每小时原始评分 (Raw Hourly Scores) - 修复版
-- 修复内容:
-- 1. 修复 CV 组件的 CTE 结构，使其融入主链条
-- 2. 修正 Coagulation 表名引用 (sofa2_stage1_coag)
-- 3. 修正 Kidney/Liver 列名引用不一致问题
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_hourly_raw CASCADE;

CREATE TABLE mimiciv_derived.sofa2_hourly_raw AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
),

-- 1. Brain (GCS + Delirium)
brain_sofa AS (
    SELECT 
        co.stay_id, 
        co.hr,
        CASE 
            -- SOFA 2.0: 谵妄药物且 GCS 15 (raw score 0) -> 1分
            WHEN COALESCE(br.brain_score_final, 0) = 0 AND COALESCE(ds.on_delirium_med, 0) = 1 THEN 1
            ELSE COALESCE(br.brain_score_final, 0)
        END AS brain_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_brain br 
        ON co.stay_id = br.stay_id 
        AND co.endtime > br.starttime AND co.endtime <= br.endtime
    LEFT JOIN mimiciv_derived.sofa2_stage1_delirium ds 
        ON co.stay_id = ds.stay_id AND co.hr = ds.hr
),

-- 2. Respiratory (PF/SF/ECMO)
resp_sofa AS (
    SELECT 
        co.stay_id, 
        co.hr,
        CASE
            -- ECMO（任何类型）→ 呼吸4分
            WHEN ec.is_ecmo = 1 THEN 4
            -- PF Ratio
            WHEN ox.pf_ratio IS NOT NULL THEN
                CASE 
                    WHEN ox.pf_ratio <= 75 AND rs.with_resp_support = 1 THEN 4
                    WHEN ox.pf_ratio <= 150 AND rs.with_resp_support = 1 THEN 3
                    WHEN ox.pf_ratio <= 225 THEN 2
                    WHEN ox.pf_ratio <= 300 THEN 1
                    ELSE 0
                END
            -- SF Ratio Fallback (SpO2 < 98%)
            WHEN ox.sf_ratio IS NOT NULL AND ox.raw_spo2 < 98 THEN
                CASE 
                    WHEN ox.sf_ratio <= 120 AND rs.with_resp_support = 1 THEN 4
                    WHEN ox.sf_ratio <= 200 AND rs.with_resp_support = 1 THEN 3
                    WHEN ox.sf_ratio <= 250 THEN 2
                    WHEN ox.sf_ratio <= 300 THEN 1
                    ELSE 0
                END
            ELSE 0
        END AS respiratory_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_resp_support rs 
        ON co.stay_id = rs.stay_id AND co.hr = rs.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_oxygen ox 
        ON co.stay_id = ox.stay_id AND co.hr = ox.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_mech ec 
        ON co.stay_id = ec.stay_id AND co.hr = ec.hr
),

-- 3. Cardiovascular
cv_data AS (
    SELECT co.stay_id, co.hr,
        -- ECMO类型标记
        MAX(mech.is_ecmo) as has_ecmo,
        MAX(mech.is_va_ecmo) as has_va_ecmo,
        MAX(mech.is_vv_ecmo) as has_vv_ecmo,
        MAX(mech.is_ecmo_unknown_type) as has_ecmo_unknown,
        MAX(mech.is_other_mech) as has_other_mech, 
        -- 血压和血管活性药
        MIN(vs.mbp) as mbp_min,
        MAX(va.norepinephrine) as rate_nor, 
        MAX(va.epinephrine) as rate_epi, 
        MAX(va.dopamine) as rate_dop,
        MAX(va.dobutamine) as rate_dob, 
        MAX(va.vasopressin) as rate_vas, 
        MAX(va.phenylephrine) as rate_phe, 
        MAX(va.milrinone) as rate_mil
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_mech mech 
        ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN mimiciv_derived.vitalsign vs 
        ON co.stay_id = vs.stay_id AND vs.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN mimiciv_derived.vasoactive_agent va 
        ON co.stay_id = va.stay_id 
        AND va.starttime < co.endtime 
        AND COALESCE(va.endtime, co.endtime) > co.starttime
        AND co.endtime >= va.starttime + INTERVAL '1 HOUR'  -- 持续≥1小时
    GROUP BY co.stay_id, co.hr
),
cv_sofa AS (
    SELECT stay_id, hr,
        CASE
            -- ========== Score 4 ==========
            -- 1. 其他机械循环支持（IABP, Impella, VAD）
            WHEN COALESCE(has_other_mech, 0) = 1 THEN 4
            -- 2. VA-ECMO 或 VAV-ECMO
            WHEN COALESCE(has_va_ecmo, 0) = 1 THEN 4
            -- 3. 有ECMO但非VV（包括未知类型）→ 4分
            WHEN COALESCE(has_ecmo, 0) = 1 
                 AND COALESCE(has_vv_ecmo, 0) = 0 THEN 4   -- ✅ 添加 THEN 4
            -- 4. 高剂量血管活性药
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.4 THEN 4
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.2 AND other_drug = 1 THEN 4
            WHEN dop_score = 4 THEN 4
            
            -- ========== Score 3 ==========
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.2 THEN 3
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0 AND other_drug = 1 THEN 3
            WHEN dop_score = 3 THEN 3
            
            -- ========== Score 2 ==========
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0 THEN 2
            WHEN other_drug = 1 THEN 2
            WHEN dop_score = 2 THEN 2   -- ✅ 添加这行（原代码缺失）
            
            -- ========== Score 0-1 (MAP only) ==========
            WHEN COALESCE(mbp_min, 70) < 40 THEN 4
            WHEN COALESCE(mbp_min, 70) < 50 THEN 3
            WHEN COALESCE(mbp_min, 70) < 60 THEN 2
            WHEN COALESCE(mbp_min, 70) < 70 THEN 1
            ELSE 0
        END AS cardiovascular_score
    FROM (
        SELECT *,
            CASE 
                WHEN rate_dop > 40 THEN 4 
                WHEN rate_dop > 20 THEN 3 
                WHEN rate_dop > 0 THEN 2 
                ELSE 0 
            END as dop_score,
            CASE 
                WHEN (COALESCE(rate_dob,0) > 0 
                      OR COALESCE(rate_vas,0) > 0 
                      OR COALESCE(rate_phe,0) > 0 
                      OR COALESCE(rate_mil,0) > 0 
                      OR COALESCE(rate_dop,0) > 0) 
                THEN 1 ELSE 0 
            END as other_drug
        FROM cv_data
    ) x
),

-- 4. Coagulation (Fix: 使用正确的 Step 2 表名)
coag_sofa AS (
    SELECT 
        co.stay_id, 
        co.hr,
        CASE
            WHEN cg.platelet_min <= 50  THEN 4 
            WHEN cg.platelet_min <= 80  THEN 3 
            WHEN cg.platelet_min <= 100 THEN 2 
            WHEN cg.platelet_min <= 150 THEN 1 
            ELSE 0
        END AS coagulation_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_coag cg 
        ON co.stay_id = cg.stay_id AND co.hr = cg.hr
),

-- 5. Liver
liver_sofa AS (
    SELECT 
        co.stay_id, 
        co.hr,
        CASE
            WHEN liv.bilirubin_max > 12.0 THEN 4
            WHEN liv.bilirubin_max > 6.0  THEN 3
            WHEN liv.bilirubin_max > 3.0  THEN 2 
            WHEN liv.bilirubin_max > 1.2  THEN 1
            ELSE 0
        END AS liver_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_liver liv 
        ON co.stay_id = liv.stay_id AND co.hr = liv.hr
),

-- 6. Kidney (Fix: 别名一致性 + 时间窗口修复)
kidney_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        l.creatinine,
        l.potassium,
        l.ph,
        l.bicarbonate,
        r.on_rrt,
        u.weight,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,
        u.cnt_6h,
        u.cnt_12h,
        u.cnt_24h,
        u.urine_rate_ml_kg_h,        -- **新增：修复后的尿量速率**
        u.time_window_status,        -- **新增：时间窗口状态**
        CASE
            -- Score 4: RRT或Virtual RRT（需要足够数据进行评估）
            WHEN r.on_rrt = 1 THEN 4
            WHEN (l.creatinine > 1.2 OR u.urine_rate_ml_kg_h < 0.3)
                 AND (l.potassium >= 6.0 OR (l.ph <= 7.2 AND l.bicarbonate <= 12))
                 AND u.time_window_status IN ('full_24h', 'full_12h', 'full_6h') THEN 4

            -- Score 3: 严重肾功能不全
            WHEN l.creatinine > 3.5 THEN 3
            WHEN u.urine_rate_ml_kg_h < 0.3 AND u.time_window_status IN ('full_24h', 'full_12h') THEN 3
            WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3

            -- Score 2: 中度肾功能不全
            WHEN l.creatinine > 2.0 THEN 2
            WHEN u.urine_rate_ml_kg_h < 0.5 AND u.time_window_status IN ('full_12h', 'full_6h') THEN 2

            -- Score 1: 轻度肾功能不全
            WHEN l.creatinine > 1.2 THEN 1
            WHEN u.urine_rate_ml_kg_h < 0.5 AND u.time_window_status = 'full_6h' THEN 1

            ELSE 0
        END AS kidney_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs l ON co.stay_id = l.stay_id AND co.hr = l.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt r ON co.stay_id = r.stay_id AND co.hr = r.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON co.stay_id = u.stay_id AND co.hr = u.hr
)

-- 最终合并
SELECT
    co.stay_id, co.hadm_id, co.subject_id, co.hr, co.starttime, co.endtime,
    COALESCE(br.brain_score, 0) AS brain_score,
    COALESCE(rs.respiratory_score, 0) AS respiratory_score,
    COALESCE(cv.cardiovascular_score, 0) AS cardiovascular_score,
    COALESCE(lv.liver_score, 0) AS liver_score,
    COALESCE(kd.kidney_score, 0) AS kidney_score,
    COALESCE(cg.coagulation_score, 0) AS hemostasis_score -- 注意: 这里列名映射为 hemostasis_score 以匹配 Step 5
FROM co
LEFT JOIN brain_sofa br ON co.stay_id = br.stay_id AND co.hr = br.hr
LEFT JOIN resp_sofa rs ON co.stay_id = rs.stay_id AND co.hr = rs.hr
LEFT JOIN cv_sofa cv ON co.stay_id = cv.stay_id AND co.hr = cv.hr
LEFT JOIN liver_sofa lv ON co.stay_id = lv.stay_id AND co.hr = lv.hr
LEFT JOIN kidney_sofa kd ON co.stay_id = kd.stay_id AND co.hr = kd.hr
LEFT JOIN coag_sofa cg ON co.stay_id = cg.stay_id AND co.hr = cg.hr; -- Fix: 使用 coag_sofa

CREATE INDEX idx_sofa2_raw_calc ON mimiciv_derived.sofa2_hourly_raw(stay_id, hr);