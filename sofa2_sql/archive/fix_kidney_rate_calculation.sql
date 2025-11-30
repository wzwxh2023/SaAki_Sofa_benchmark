-- =================================================================
-- 修复SOFA2肾脏评分中的尿量速率计算错误
-- 问题：使用动态cnt_24h导致尿量速率被人为夸大，更多患者被误判为肾功能不全
-- 解决：统一使用固定24小时进行计算
-- =================================================================

-- 重新计算肾脏评分（修复版）
DROP TABLE IF EXISTS mimiciv_derived.sofa2_hourly_raw_fixed CASCADE;

CREATE TABLE mimiciv_derived.sofa2_hourly_raw_fixed AS
WITH
-- 基础时间网格（保持与原脚本一致）
co AS (
    SELECT
        ih.stay_id,
        ie.hadm_id,
        ie.subject_id,
        hr,
        ih.endtime - INTERVAL '1 HOUR' AS starttime,
        ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
),

-- 脑部评分（保持不变）
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

-- 呼吸评分（保持不变）
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

-- 心血管评分（保持不变）
cv_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- 4分条件
            WHEN coalesce(has_other_mech, 0) = 1 THEN 4
            WHEN coalesce(has_va_ecmo, 0) = 1 THEN 4
            WHEN coalesce(has_ecmo, 0) = 1 AND coalesce(has_vv_ecmo, 0) = 0 THEN 4
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0.4 THEN 4
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0.2 AND other_drug = 1 THEN 4
            WHEN dop_score = 4 THEN 4
            -- 3分条件
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0.2 THEN 3
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0 AND other_drug = 1 THEN 3
            WHEN dop_score = 3 THEN 3
            -- 2分条件
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0 THEN 2
            WHEN other_drug = 1 THEN 2
            WHEN dop_score = 2 THEN 2
            -- 1分条件
            WHEN coalesce(mbp_min, 70) < 70 THEN 1
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0 THEN 1
            WHEN other_drug = 1 THEN 1
            WHEN dop_score = 1 THEN 1
            ELSE 0
        END AS cardiovascular_score
    FROM (
        SELECT
            co.*,
            -- 机械支持标记
            CASE
                WHEN mech.itemid IN (224322, 227980, 225980, 228866, 228154, 229671, 229897, 229898, 229899, 229900) THEN 1
                ELSE 0
            END AS has_other_mech,
            CASE
                WHEN mech.itemid = 229268 AND mech.value IN ('VA', 'VAV') THEN 1
                ELSE 0
            END AS has_va_ecmo,
            CASE
                WHEN mech.itemid = 229268 AND mech.value = 'VV' THEN 1
                ELSE 0
            END AS has_vv_ecmo,
            CASE
                WHEN mech.itemid IN (224660, 229270, 229277, 229280, 229278, 229363, 229364, 229365, 228193) THEN 1
                ELSE 0
            END AS has_ecmo,
            -- 血管活性药物
            MIN(vs.mbp) as mbp_min,
            va.norepinephrine as rate_nor,
            va.epinephrine as rate_epi,
            va.dopamine as rate_dop,
            va.dobutamine as rate_dob,
            va.vasopressin as rate_vas,
            va.phenylephrine as rate_phe,
            va.milrinone as rate_mil
        FROM co
        LEFT JOIN mimiciv_derived.vitalsign vs
            ON co.stay_id = vs.stay_id
            AND vs.charttime BETWEEN co.starttime AND co.endtime
        LEFT JOIN mimiciv_derived.vasoactive_agent va
            ON co.stay_id = va.stay_id
            AND va.starttime < co.endtime
            AND COALESCE(va.endtime, co.endtime) > co.starttime + INTERVAL '1 HOUR'
        LEFT JOIN mimiciv_derived.sofa2_stage1_mech mech
            ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    ) cv_data
    WHERE cv_data.mbp_min IS NOT NULL
),
cv_sofa_processed AS (
    SELECT
        stay_id, hr,
        cardiovascular_score,
        CASE
            WHEN dop_score = 4 THEN 4
            WHEN dop_score = 3 THEN 3
            WHEN dop_score = 2 THEN 2
            WHEN dop_score = 1 THEN 1
            ELSE 0
        END AS dop_score
    FROM cv_data
),

-- 凝血评分（保持不变）
coag_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN cg.platelet_min <= 50 THEN 4
            WHEN cg.platelet_min <= 80 THEN 3
            WHEN cg.platelet_min <= 100 THEN 2
            WHEN cg.platelet_min <= 150 THEN 1
            ELSE 0
        END AS coagulation_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_coag cg
        ON co.stay_id = cg.stay_id AND co.hr = cg.hr
),

-- 肝脏评分（保持不变）
liver_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN liv.bilirubin_max > 12.0 THEN 4
            WHEN liv.bilirubin_max > 6.0 THEN 3
            WHEN liv.bilirubin_max > 3.0 THEN 2
            WHEN liv.bilirubin_max > 1.2 THEN 1
            ELSE 0
        END AS liver_score
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_liver liv
        ON co.stay_id = liv.stay_id AND co.hr = liv.hr
),

-- **修复后的肾脏评分**
kidney_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        kl.creatinine,
        kl.potassium,
        kl.ph,
        kl.bicarbonate,
        rr.on_rrt,
        u.weight,
        u.uo_sum_6h,
        u.uo_sum_12h,
        u.uo_sum_24h,
        u.cnt_6h,
        u.cnt_12h,
        u.cnt_24h,

        -- **修复：使用固定24小时计算尿量速率**
        CASE
            -- Score 4: RRT或Virtual RRT
            WHEN rr.on_rrt = 1 THEN 4
            WHEN (kl.creatinine > 1.2 OR (u.weight > 0 AND u.uo_sum_24h / u.weight / 24 < 0.3))
                 AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
            THEN 4

            -- Score 3: 严重肾功能不全
            WHEN kl.creatinine > 3.5 THEN 3
            WHEN u.weight > 0 AND u.uo_sum_24h / u.weight / 24 < 0.3 THEN 3
            WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3

            -- Score 2: 中度肾功能不全
            WHEN kl.creatinine > 2.0 THEN 2
            WHEN u.weight > 0 AND u.cnt_12h > 0 AND u.uo_sum_12h / u.weight / 12 < 0.5 THEN 2

            -- Score 1: 轻度肾功能不全
            WHEN kl.creatinine > 1.2 THEN 1
            WHEN u.weight > 0 AND u.cnt_6h > 0 AND u.uo_sum_6h / u.weight / 6 < 0.5 THEN 1

            ELSE 0
        END AS kidney_score

    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON co.stay_id = kl.stay_id AND co.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON co.stay_id = rr.stay_id AND co.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine u ON co.stay_id = u.stay_id AND co.hr = u.hr
)

-- 最终合并
SELECT
    co.stay_id,
    co.hadm_id,
    co.subject_id,
    co.hr,
    co.starttime,
    co.endtime,
    COALESCE(br.brain_score, 0) AS brain_score,
    COALESCE(rs.respiratory_score, 0) AS respiratory_score,
    COALESCE(cv.cardiovascular_score, 0) AS cardiovascular_score,
    COALESCE(lv.liver_score, 0) AS liver_score,
    COALESCE(kd.kidney_score, 0) AS kidney_score,
    COALESCE(cg.coagulation_score, 0) AS hemostasis_score

FROM co
LEFT JOIN brain_sofa br ON co.stay_id = br.stay_id AND co.hr = br.hr
LEFT JOIN resp_sofa rs ON co.stay_id = rs.stay_id AND co.hr = rs.hr
LEFT JOIN cv_sofa cv ON co.stay_id = cv.stay_id AND co.hr = cv.hr
LEFT JOIN coag_sofa cg ON co.stay_id = cg.stay_id AND co.hr = cg.hr
LEFT JOIN liver_sofa lv ON co.stay_id = lv.stay_id AND co.hr = lv.hr
LEFT JOIN kidney_sofa kd ON co.stay_id = kd.stay_id AND co.hr = kd.hr;

CREATE INDEX idx_sofa2_raw_fixed_calc ON mimiciv_derived.sofa2_hourly_raw_fixed(stay_id, hr);

-- 4. 创建修复后的first_day_sofa2表
DROP TABLE IF EXISTS mimiciv_derived.first_day_sofa2_fixed CASCADE;

CREATE TABLE mimiciv_derived.first_day_sofa2_fixed AS
SELECT
    stay_id,
    subject_id,
    hadm_id,

    -- 取0-23小时内各系统的最高分（修复后）
    MAX(brain_score) AS brain,
    MAX(respiratory_score) AS respiratory,
    MAX(cardiovascular_score) AS cardiovascular,
    MAX(liver_score) AS liver,
    MAX(kidney_score) AS kidney,
    MAX(hemostasis_score) AS hemostasis,

    -- 修复后的总分
    MAX(brain_score + respiratory_score + cardiovascular_score + liver_score +
        kidney_score + hemostasis_score) AS sofa2_total_fixed

FROM mimiciv_derived.sofa2_hourly_raw_fixed
WHERE hr BETWEEN 0 AND 23  -- ICU入院后24小时（0-23小时）
GROUP BY stay_id, subject_id, hadm_id;

-- 创建索引
CREATE INDEX idx_first_day_sofa2_fixed_stay ON mimiciv_derived.first_day_sofa2_fixed(stay_id);
CREATE INDEX idx_first_day_sofa2_fixed_subject ON mimiciv_derived.first_day_sofa2_fixed(subject_id);
CREATE INDEX idx_first_day_sofa2_fixed_hadm ON mimiciv_derived.first_day_sofa2_fixed(hadm_id);
CREATE INDEX idx_first_day_sofa2_fixed_total ON mimiciv_derived.first_day_sofa2_fixed(sofa2_total_fixed);

-- 5. 验证修复效果
WITH score_comparison AS (
    SELECT
        fs.stay_id,
        fs.renal as traditional_renal,
        fs2_fixed.kidney as sofa2_kidney_fixed,
        fs2_fixed.sofa2_total_fixed
    FROM mimiciv_derived.first_day_sofa fs
    LEFT JOIN mimiciv_derived.first_day_sofa2_fixed fs2_fixed ON fs.stay_id = fs2_fixed.stay_id
    WHERE fs.renal IS NOT NULL OR fs2_fixed.kidney IS NOT NULL
)
SELECT
    'Score Distribution Comparison' as analysis_type,
    scoring_system,
    kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM (
    SELECT 'Traditional SOFA' as scoring_system, traditional_renal, count(*) as kidney_score
    FROM score_comparison WHERE traditional_renal IS NOT NULL

    UNION ALL

    SELECT 'SOFA2 Fixed' as scoring_system, sofa2_kidney_fixed, count(*) as kidney_score
    FROM score_comparison WHERE sofa2_kidney_fixed IS NOT NULL
)
GROUP BY scoring_system, kidney_score
ORDER BY scoring_system, kidney_score;

-- 6. 提供修复建议
SELECT
    'Fix Summary' as analysis_type,
    'Fixed kidney rate calculation using 24h instead of cnt_24h' as recommendation,
    'This should normalize SOFA2 kidney scores to match traditional SOFA distribution' as expected_result,
    'Compare first_day_sofa2_fixed with first_day_sofa2' as validation_step;

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.sofa2_hourly_raw_fixed IS 'Fixed SOFA2 hourly scores with corrected kidney rate calculation';
COMMENT ON TABLE mimiciv_derived.first_day_sofa2_fixed IS 'First day SOFA2 scores (0-23 hours after ICU admission) - Kidney scoring fixed';