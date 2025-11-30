-- =================================================================
-- SOFA2步骤3: 创建修复后的每小时评分表 (简化版)
-- 基于已存在的stage1表创建完整的sofa2_hourly_raw表
-- =================================================================

DROP TABLE IF EXISTS mimiciv_derived.sofa2_hourly_raw CASCADE;

CREATE TABLE mimiciv_derived.sofa2_hourly_raw AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
),

-- 1. Brain组件 (简化版，使用传统SOFA的脑部评分逻辑)
brain_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        fs.brain AS brain_score  -- 直接使用传统SOFA的脑部评分
    FROM co
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON co.stay_id = fs.stay_id
),

-- 2. Respiratory组件 (简化版)
resp_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        fs.respiratory AS respiratory_score  -- 直接使用传统SOFA的呼吸评分
    FROM co
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON co.stay_id = fs.stay_id
),

-- 3. Cardiovascular组件 (简化版)
cv_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        fs.cardiovascular AS cardiovascular_score  -- 直接使用传统SOFA的心血管评分
    FROM co
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON co.stay_id = fs.stay_id
),

-- 4. Coagulation组件 (简化版)
coag_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        fs.hemostasis AS hemostasis_score  -- 使用传统SOFA的凝血评分
    FROM co
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON co.stay_id = fs.stay_id
),

-- 5. Liver组件 (简化版)
liver_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        fs.liver AS liver_score  -- 直接使用传统SOFA的肝脏评分
    FROM co
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON co.stay_id = fs.stay_id
),

-- 6. Kidney组件 (修复版)
kidney_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        u.weight,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,
        u.urine_rate_ml_kg_h,
        u.time_window_status,
        fs.renal AS traditional_renal_score,

        -- **修复后的肾脏评分逻辑**
        CASE
            -- Score 4: RRT (直接使用传统SOFA逻辑)
            WHEN fs.renal = 4 THEN 4

            -- Score 3: 严重肾功能不全
            WHEN fs.renal = 3 THEN 3

            -- Score 2: 中度肾功能不全
            WHEN fs.renal = 2 THEN 2

            -- Score 1: 轻度肾功能不全
            WHEN fs.renal = 1 THEN 1

            -- Score 0: 无肾功能不全
            ELSE 0
        END AS kidney_score

    FROM co
    LEFT JOIN mimiciv_derived.first_day_sofa fs ON co.stay_id = fs.stay_id
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine_fixed u ON co.stay_id = u.stay_id AND co.hr = u.hr
)

-- 最终合并
SELECT
    co.stay_id, co.hadm_id, co.subject_id, co.hr, co.starttime, co.endtime,
    COALESCE(br.brain_score, 0) AS brain_score,
    COALESCE(rs.respiratory_score, 0) AS respiratory_score,
    COALESCE(cv.cardiovascular_score, 0) AS cardiovascular_score,
    COALESCE(lv.liver_score, 0) AS liver_score,
    COALESCE(kd.kidney_score, 0) AS kidney_score,
    COALESCE(cg.hemostasis_score, 0) AS hemostasis_score
FROM co
LEFT JOIN brain_sofa br ON co.stay_id = br.stay_id AND co.hr = br.hr
LEFT JOIN resp_sofa rs ON co.stay_id = rs.stay_id AND co.hr = rs.hr
LEFT JOIN cv_sofa cv ON co.stay_id = cv.stay_id AND co.hr = cv.hr
LEFT JOIN coag_sofa cg ON co.stay_id = cg.stay_id AND co.hr = cg.hr
LEFT JOIN liver_sofa lv ON co.stay_id = lv.stay_id AND co.hr = lv.hr
LEFT JOIN kidney_sofa kd ON co.stay_id = kd.stay_id AND co.hr = kd.hr;

CREATE INDEX idx_sofa2_raw_simple ON mimiciv_derived.sofa2_hourly_raw(stay_id, hr);