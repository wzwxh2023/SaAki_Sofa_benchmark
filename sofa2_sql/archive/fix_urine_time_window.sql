-- =================================================================
-- 修复SOFA2尿量计算的时间窗口问题
-- 问题：滑动窗口在早期小时（如hr=0,1,2...）包含的数据不足24小时，
--      导致尿量速率被错误计算，多数早期小时被误判为肾功能不全
-- 解决：只有在有足够数据时才使用对应的滑动窗口进行评分
-- =================================================================

-- 1. 首先分析当前的问题
WITH hourly_urine_analysis AS (
    SELECT
        stay_id,
        hr,
        uo_sum_6h,
        uo_sum_12h,
        uo_sum_24h,
        cnt_6h,
        cnt_12h,
        cnt_24h,
        weight,

        -- 当前的错误计算方式
        CASE WHEN cnt_24h > 0 AND weight > 0
             THEN uo_sum_24h / weight / cnt_24h
             ELSE NULL END as current_urine_rate_24h,

        -- 实际应该的计算方式
        CASE WHEN hr >= 0 AND weight > 0 THEN
             CASE
                 WHEN hr >= 24 THEN uo_sum_24h / weight / 24  -- 有24小时数据
                 WHEN hr >= 12 THEN uo_sum_12h / weight / 12  -- 只有12小时数据
                 WHEN hr >= 6 THEN uo_sum_6h / weight / 6    -- 只有6小时数据
                 ELSE NULL  -- 数据不足，不计算
             END
             ELSE NULL END as corrected_urine_rate
    FROM mimiciv_derived.sofa2_stage1_urine
    WHERE hr BETWEEN 0 AND 23
    AND weight > 0
)
SELECT
    'Urine Rate Calculation Problem' as analysis_type,
    hr as hour_after_admission,
    COUNT(*) as total_records,
    ROUND(AVG(current_urine_rate_24h), 3) as avg_current_rate_ml_kg_h,
    ROUND(AVG(corrected_urine_rate), 3) as avg_corrected_rate_ml_kg_h,
    COUNT(CASE WHEN current_urine_rate_24h < 0.3 THEN 1 END) as current_score_3_count,
    COUNT(CASE WHEN corrected_urine_rate < 0.3 THEN 1 END) as corrected_score_3_count,
    ROUND(COUNT(CASE WHEN current_urine_rate_24h < 0.3 THEN 1 END) * 100.0 / COUNT(*), 2) as current_score_3_percentage,
    ROUND(COUNT(CASE WHEN corrected_urine_rate < 0.3 THEN 1 END) * 100.0 / COUNT(*), 2) as corrected_score_3_percentage
FROM hourly_urine_analysis
GROUP BY hr
ORDER BY hr;

-- 2. 创建修复后的尿量表
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_urine_fixed CASCADE;

CREATE TABLE mimiciv_derived.sofa2_stage1_urine_fixed AS
WITH
-- 1. 准备体重（与原step2.sql相同）
weight_avg_whole_stay AS (
    SELECT stay_id, AVG(weight) as weight_full_avg
    FROM mimiciv_derived.weight_durations
    WHERE weight > 0
    GROUP BY stay_id
),
weight_from_ce AS (
    SELECT
        stay_id,
        AVG(
            CASE
                WHEN itemid = 226531 THEN valuenum * 0.453592  -- lbs → kg
                ELSE valuenum                                   -- 已经是kg
            END
        ) as weight_ce
    FROM mimiciv_icu.chartevents
    WHERE itemid IN (224639, 226512, 226531)
      AND valuenum > 0
      AND (
          (itemid IN (224639, 226512) AND valuenum BETWEEN 20 AND 300)
          OR
          (itemid = 226531 AND valuenum BETWEEN 44 AND 660)
      )
    GROUP BY stay_id
),
weight_final AS (
    SELECT
        ie.stay_id,
        COALESCE(
            fd.weight_admit,                    -- 1. 入院体重
            fd.weight,                          -- 2. 首日均值
            ws.weight_full_avg,                 -- 3. 全程均值
            ce.weight_ce,                       -- 4. chartevents原始
            CASE WHEN p.gender = 'F' THEN 70.0  -- 5. 性别中位数（女）
                 ELSE 83.3                      -- 5. 性别中位数（男）
            END
        ) AS weight
    FROM mimiciv_icu.icustays ie
    JOIN mimiciv_hosp.patients p ON ie.subject_id = p.subject_id
    LEFT JOIN mimiciv_derived.first_day_weight fd ON ie.stay_id = fd.stay_id
    LEFT JOIN weight_avg_whole_stay ws ON ie.stay_id = ws.stay_id
    LEFT JOIN weight_from_ce ce ON ie.stay_id = ce.stay_id
),

-- 2. 准备网格数据（使用清洁的尿量数据）
uo_grid AS (
    SELECT
        ih.stay_id,
        ih.hr,
        ih.endtime,
        COALESCE(SUM(uo.urineoutput), 0) AS uo_vol_hourly
    FROM mimiciv_derived.icustay_hourly ih
    LEFT JOIN mimiciv_derived.urine_output uo  -- 使用原始尿量数据
           ON ih.stay_id = uo.stay_id
           AND uo.charttime > ih.endtime - INTERVAL '1 HOUR'
           AND uo.charttime <= ih.endtime
    WHERE ih.hr >= -24
    GROUP BY ih.stay_id, ih.hr, ih.endtime
)

-- 3. 计算滑动窗口（保持原样）
SELECT
    g.stay_id,
    g.hr,
    w.weight,

    -- 保持原有的滑动窗口计算
    SUM(uo_vol_hourly) OVER w6 AS uo_sum_6h,
    SUM(uo_vol_hourly) OVER w12 AS uo_sum_12h,
    SUM(uo_vol_hourly) OVER w24 AS uo_sum_24h,

    COUNT(*) OVER w6 AS cnt_6h,
    COUNT(*) OVER w12 AS cnt_12h,
    COUNT(*) OVER w24 AS cnt_24h,

    -- **新增：修正后的尿量速率**
    CASE
        WHEN hr >= 0 AND w.weight > 0 THEN
            CASE
                WHEN hr >= 24 THEN uo_sum_24h / w.weight / 24  -- 有24小时数据，用24小时计算
                WHEN hr >= 12 THEN uo_sum_12h / w.weight / 12  -- 有12小时数据，用12小时计算
                WHEN hr >= 6 THEN uo_sum_6h / w.weight / 6    -- 有6小时数据，用6小时计算
                ELSE NULL  -- 前6小时数据不足，不进行速率评估
            END
        ELSE NULL
    END AS urine_rate_corrected_ml_kg_h,

    -- **新增：标记数据是否足够进行评分**
    CASE
        WHEN hr >= 24 THEN 'sufficient_24h'
        WHEN hr >= 12 THEN 'sufficient_12h'
        WHEN hr >= 6 THEN 'sufficient_6h'
        ELSE 'insufficient'
    END AS data_sufficiency_flag

FROM uo_grid g
JOIN weight_final w ON g.stay_id = w.stay_id
WINDOW
    w6  AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 5 PRECEDING AND CURRENT ROW),
    w12 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 11 PRECEDING AND CURRENT ROW),
    w24 AS (PARTITION BY g.stay_id ORDER BY g.hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW);

CREATE INDEX idx_st1_urine_fixed ON mimiciv_derived.sofa2_stage1_urine_fixed(stay_id, hr);

-- 3. 创建修复后的肾脏评分逻辑
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

-- 其他系统评分保持不变，这里只展示修复后的肾脏评分
-- 脑部评分（保持不变）
brain_sofa AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
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
            WHEN ec.is_ecmo = 1 THEN 4
            WHEN ox.pf_ratio IS NOT NULL THEN
                CASE
                    WHEN ox.pf_ratio <= 75 AND rs.with_resp_support = 1 THEN 4
                    WHEN ox.pf_ratio <= 150 AND rs.with_resp_support = 1 THEN 3
                    WHEN ox.pf_ratio <= 225 THEN 2
                    WHEN ox.pf_ratio <= 300 THEN 1
                    ELSE 0
                END
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
            WHEN coalesce(has_other_mech, 0) = 1 THEN 4
            WHEN coalesce(has_va_ecmo, 0) = 1 THEN 4
            WHEN coalesce(has_ecmo, 0) = 1 AND coalesce(has_vv_ecmo, 0) = 0 THEN 4
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0.4 THEN 4
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0.2 AND other_drug = 1 THEN 4
            WHEN dop_score = 4 THEN 4
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0.2 THEN 3
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0 AND other_drug = 1 THEN 3
            WHEN dop_score = 3 THEN 3
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0 THEN 2
            WHEN other_drug = 1 THEN 2
            WHEN dop_score = 2 THEN 2
            WHEN coalesce(mbp_min, 70) < 70 THEN 1
            WHEN (COALESCE(rate_nor, 0) + COALESCE(rate_epi, 0)) > 0 THEN 1
            WHEN other_drug = 1 THEN 1
            WHEN dop_score = 1 THEN 1
            ELSE 0
        END AS cardiovascular_score
    FROM (
        SELECT
            co.*,
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
                WHEN mech.itemid IN (224660, 229270, 229277, 229280, 229363, 229364, 229365, 228193) THEN 1
                ELSE 0
            END AS has_ecmo,
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
        u.urine_rate_corrected_ml_kg_h,
        u.data_sufficiency_flag,

        -- **修复后的肾脏评分逻辑**
        CASE
            -- Score 4: RRT或Virtual RRT（需要足够数据进行评估）
            WHEN rr.on_rrt = 1 THEN 4
            WHEN (kl.creatinine > 1.2 OR u.urine_rate_corrected_ml_kg_h < 0.3)
                 AND (kl.potassium >= 6.0 OR (kl.ph <= 7.2 AND kl.bicarbonate <= 12))
                 AND u.data_sufficiency_flag IN ('sufficient_24h', 'sufficient_12h', 'sufficient_6h') THEN 4

            -- Score 3: 严重肾功能不全
            WHEN kl.creatinine > 3.5 THEN 3
            WHEN u.urine_rate_corrected_ml_kg_h < 0.3 AND u.data_sufficiency_flag IN ('sufficient_24h', 'sufficient_12h') THEN 3
            WHEN u.uo_sum_12h < 5.0 AND u.cnt_12h >= 12 THEN 3

            -- Score 2: 中度肾功能不全
            WHEN kl.creatinine > 2.0 THEN 2
            WHEN u.urine_rate_corrected_ml_kg_h < 0.5 AND u.data_sufficiency_flag IN ('sufficient_12h', 'sufficient_6h') THEN 2

            -- Score 1: 轻度肾功能不全
            WHEN kl.creatinine > 1.2 THEN 1
            WHEN u.urine_rate_corrected_ml_kg_h < 0.5 AND u.data_sufficiency_flag = 'sufficient_6h' THEN 1

            ELSE 0
        END AS kidney_score

    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON co.stay_id = kl.stay_id AND co.hr = kl.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rr ON co.stay_id = rr.stay_id AND co.hr = rr.hr
    LEFT JOIN mimiciv_derived.sofa2_stage1_urine_fixed u ON co.stay_id = u.stay_id AND co.hr = u.hr
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

CREATE INDEX idx_sofa2_raw_fixed ON mimiciv_derived.sofa2_hourly_raw_fixed(stay_id, hr);

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
    'Before/After Fix Comparison' as analysis_type,
    scoring_system,
    kidney_score,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM (
    SELECT 'Traditional SOFA' as scoring_system, traditional_renal, count(*) as kidney_score
    FROM score_comparison WHERE traditional_renal IS NOT NULL
    GROUP BY traditional_renal

    UNION ALL

    SELECT 'SOFA2 Fixed' as scoring_system, sofa2_kidney_fixed, count(*) as kidney_score
    FROM score_comparison WHERE sofa2_kidney_fixed IS NOT NULL
    GROUP BY sofa2_kidney_fixed
) scores
GROUP BY scoring_system, kidney_score
ORDER BY scoring_system, kidney_score;

-- 6. 按小时验证修复效果
SELECT
    'Hour-by-Hour Verification' as analysis_type,
    hr as hour_after_admission,
    COUNT(*) as total_patients,
    ROUND(AVG(urine_rate_corrected_ml_kg_h), 3) as avg_corrected_urine_rate,
    COUNT(CASE WHEN urine_rate_corrected_ml_kg_h < 0.3 THEN 1 END) as patients_below_threshold,
    ROUND(COUNT(CASE WHEN urine_rate_corrected_ml_kg_h < 0.3 THEN 1 END) * 100.0 / COUNT(*), 2) as percentage_below_threshold,
    data_sufficiency_flag
FROM mimiciv_derived.sofa2_stage1_urine_fixed
WHERE hr BETWEEN 0 AND 23
AND weight > 0
GROUP BY hr, data_sufficiency_flag
ORDER BY hr;

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.sofa2_stage1_urine_fixed IS 'Fixed SOFA2 stage 1 urine data with proper time window validation';
COMMENT ON TABLE mimiciv_derived.sofa2_hourly_raw_fixed IS 'Fixed SOFA2 hourly scores with corrected kidney rate calculation';
COMMENT ON TABLE mimiciv_derived.first_day_sofa2_fixed IS 'First day SOFA2 scores (0-23 hours after ICU admission) - Time window fix applied';