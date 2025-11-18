-- =================================================================
-- SOFA-2 评分系统修复版本
-- 基于100样本测试验证的正确逻辑
-- =================================================================

-- 删除已存在的表
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores CASCADE;

-- 创建SOFA2评分表
CREATE TABLE mimiciv_derived.sofa2_scores AS
WITH co AS (
    -- 基础时间序列CTE
    SELECT
        ih.stay_id,
        ie.hadm_id,
        ie.subject_id,
        hr,
        ih.endtime - INTERVAL '1 HOUR' AS starttime,
        ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
),

-- GCS数据 - 神经系统评分基础
brain_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(gcs.gcs) AS gcs_min
    FROM co
    LEFT JOIN mimiciv_derived.gcs gcs
        ON co.stay_id = gcs.stay_id
        AND co.starttime < gcs.charttime
        AND co.endtime >= gcs.charttime
    GROUP BY co.stay_id, co.hr
),

-- 呼吸系统评分 - 血气和呼吸支持数据
respiratory_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(CASE
            WHEN v.stay_id IS NULL THEN bg.pao2fio2ratio
            ELSE NULL
        END) AS pao2fio2_novent_min,
        MIN(CASE
            WHEN v.stay_id IS NOT NULL THEN bg.pao2fio2ratio
            ELSE NULL
        END) AS pao2fio2_vent_min
    FROM co
    LEFT JOIN mimiciv_derived.bg bg
        ON co.subject_id = bg.subject_id  -- 修复：使用subject_id连接
        AND co.starttime < bg.charttime
        AND co.endtime >= bg.charttime
        AND bg.specimen = 'ART.'
    LEFT JOIN mimiciv_derived.ventilation v
        ON co.stay_id = v.stay_id
        AND bg.charttime >= v.starttime
        AND bg.charttime <= v.endtime
        AND v.ventilation_status IN ('InvasiveVent', 'Tracheostomy', 'NonInvasiveVent', 'HFNC')
    GROUP BY co.stay_id, co.hr
),

-- 心血管系统评分 - 血压和血管活性药物
cardiovascular_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(v.mbp) AS mbp_min,
        MAX(CASE WHEN vaso.treatment = 'norepinephrine' THEN vaso.rate END) AS rate_norepinephrine,
        MAX(CASE WHEN vaso.treatment = 'epinephrine' THEN vaso.rate END) AS rate_epinephrine,
        MAX(CASE WHEN vaso.treatment = 'dopamine' THEN vaso.rate END) AS rate_dopamine,
        MAX(CASE WHEN vaso.treatment = 'dobutamine' THEN vaso.rate END) AS rate_dobutamine
    FROM co
    LEFT JOIN mimiciv_derived.vitalsign v
        ON co.stay_id = v.stay_id
        AND co.starttime < v.charttime
        AND co.endtime >= v.charttime
    LEFT JOIN (
        -- 血管活性药物数据聚合
        SELECT ie.stay_id, 'norepinephrine' AS treatment, vaso_rate AS rate
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.norepinephrine mv ON ie.stay_id = mv.stay_id
        UNION ALL
        SELECT ie.stay_id, 'epinephrine' AS treatment, vaso_rate AS rate
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.epinephrine mv ON ie.stay_id = mv.stay_id
        UNION ALL
        SELECT ie.stay_id, 'dobutamine' AS treatment, vaso_rate AS rate
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.dobutamine mv ON ie.stay_id = mv.stay_id
        UNION ALL
        SELECT ie.stay_id, 'dopamine' AS treatment, vaso_rate AS rate
        FROM mimiciv_icu.icustays ie
        INNER JOIN mimiciv_derived.dopamine mv ON ie.stay_id = mv.stay_id
    ) vaso ON co.stay_id = vaso.stay_id
    GROUP BY co.stay_id, co.hr
),

-- 肝脏系统评分 - 胆红素
liver_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(enz.bilirubin_total) AS bilirubin_max
    FROM co
    LEFT JOIN mimiciv_derived.enzyme enz
        ON co.hadm_id = enz.hadm_id  -- 修复：使用hadm_id连接
        AND co.starttime < enz.charttime
        AND co.endtime >= enz.charttime
    GROUP BY co.stay_id, co.hr
),

-- 肾脏系统评分 - 肌酐
kidney_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(chem.creatinine) AS creatinine_max
    FROM co
    LEFT JOIN mimiciv_derived.chemistry chem
        ON co.hadm_id = chem.hadm_id  -- 修复：使用hadm_id连接
        AND co.starttime < chem.charttime
        AND co.endtime >= chem.charttime
    GROUP BY co.stay_id, co.hr
),

-- 凝血系统评分 - 血小板
hemostasis_score AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(cbc.platelet) AS platelet_min
    FROM co
    LEFT JOIN mimiciv_derived.complete_blood_count cbc
        ON co.hadm_id = cbc.hadm_id  -- 修复：使用hadm_id连接
        AND co.starttime < cbc.charttime
        AND co.endtime >= cbc.charttime
    GROUP BY co.stay_id, co.hr
),

-- 计算每小时评分
scorecalc AS (
    SELECT
        co.stay_id,
        co.subject_id,
        co.hadm_id,
        co.hr,
        co.starttime,
        co.endtime,

        -- 神经系统评分 (GCS)
        CASE
            WHEN brain.gcs_min <= 5 THEN 4
            WHEN brain.gcs_min >= 6 AND brain.gcs_min <= 8 THEN 3
            WHEN brain.gcs_min >= 9 AND brain.gcs_min <= 12 THEN 2
            WHEN brain.gcs_min >= 13 AND brain.gcs_min <= 14 THEN 1
            WHEN brain.gcs_min = 15 THEN 0
            ELSE NULL
        END AS brain,

        -- 呼吸系统评分 (PaO2/FiO2)
        CASE
            WHEN respiratory.pao2fio2_vent_min <= 75 THEN 4
            WHEN respiratory.pao2fio2_vent_min <= 150 THEN 3
            WHEN respiratory.pao2fio2_novent_min <= 225 THEN 2
            WHEN respiratory.pao2fio2_novent_min <= 300 THEN 1
            ELSE 0
        END AS respiratory,

        -- 心血管系统评分 (血压和血管活性药)
        CASE
            WHEN cardiovascular.rate_norepinephrine > 0.1 OR cardiovascular.rate_epinephrine > 0.1 THEN 4
            WHEN cardiovascular.rate_dopamine > 15 OR cardiovascular.rate_norepinephrine > 0 OR cardiovascular.rate_epinephrine > 0 THEN 3
            WHEN cardiovascular.rate_dobutamine > 0 OR cardiovascular.rate_dopamine > 0 THEN 2
            WHEN cardiovascular.mbp_min < 70 THEN 1
            ELSE 0
        END AS cardiovascular,

        -- 肝脏系统评分 (胆红素)
        CASE
            WHEN liver.bilirubin_max > 12.0 THEN 4
            WHEN liver.bilirubin_max > 6.0 THEN 3
            WHEN liver.bilirubin_max > 3.0 THEN 2
            WHEN liver.bilirubin_max > 1.2 THEN 1
            ELSE 0
        END AS liver,

        -- 肾脏系统评分 (肌酐)
        CASE
            WHEN kidney.creatinine_max > 5.0 THEN 4
            WHEN kidney.creatinine_max > 3.5 THEN 3
            WHEN kidney.creatinine_max > 2.0 THEN 2
            WHEN kidney.creatinine_max > 1.2 THEN 1
            ELSE 0
        END AS kidney,

        -- 凝血系统评分 (血小板)
        CASE
            WHEN hemostasis.platelet_min <= 50 THEN 4
            WHEN hemostasis.platelet_min <= 80 THEN 3
            WHEN hemostasis.platelet_min <= 100 THEN 2
            WHEN hemostasis.platelet_min <= 150 THEN 1
            ELSE 0
        END AS hemostasis

    FROM co
    LEFT JOIN brain_score brain ON co.stay_id = brain.stay_id AND co.hr = brain.hr
    LEFT JOIN respiratory_score respiratory ON co.stay_id = respiratory.stay_id AND co.hr = respiratory.hr
    LEFT JOIN cardiovascular_score cardiovascular ON co.stay_id = cardiovascular.stay_id AND co.hr = cardiovascular.hr
    LEFT JOIN liver_score liver ON co.stay_id = liver.stay_id AND co.hr = liver.hr
    LEFT JOIN kidney_score kidney ON co.stay_id = kidney.stay_id AND co.hr = kidney.hr
    LEFT JOIN hemostasis_score hemostasis ON co.stay_id = hemostasis.stay_id AND co.hr = hemostasis.hr
),

-- 24小时滚动窗口评分计算
score_final AS (
    SELECT
        scorecalc.*,
        -- 使用窗口函数计算24小时滚动窗口内的最大值
        MAX(brain) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS brain_24hours,
        MAX(respiratory) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS respiratory_24hours,
        MAX(cardiovascular) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS cardiovascular_24hours,
        MAX(liver) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS liver_24hours,
        MAX(kidney) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS kidney_24hours,
        MAX(hemostasis) OVER (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
        ) AS hemostasis_24hours,
        -- 计算SOFA2总分
        COALESCE(MAX(brain) OVER (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 0) +
        COALESCE(MAX(respiratory) OVER (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 0) +
        COALESCE(MAX(cardiovascular) OVER (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 0) +
        COALESCE(MAX(liver) OVER (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 0) +
        COALESCE(MAX(kidney) OVER (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 0) +
        COALESCE(MAX(hemostasis) OVER (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 0) AS sofa2_24hours
    FROM scorecalc
    WHERE hr >= 0
)

-- 最终输出
SELECT
    stay_id,
    hadm_id,
    subject_id,
    hr,
    starttime,
    endtime,
    brain_24hours AS brain,
    respiratory_24hours AS respiratory,
    cardiovascular_24hours AS cardiovascular,
    liver_24hours AS liver,
    kidney_24hours AS kidney,
    hemostasis_24hours AS hemostasis,
    sofa2_24hours AS sofa2_total
FROM score_final;

-- 添加索引以提高查询性能
CREATE INDEX idx_sofa2_scores_stay_id ON mimiciv_derived.sofa2_scores(stay_id);
CREATE INDEX idx_sofa2_scores_subject_id ON mimiciv_derived.sofa2_scores(subject_id);
CREATE INDEX idx_sofa2_scores_hadm_id ON mimiciv_derived.sofa2_scores(hadm_id);
CREATE INDEX idx_sofa2_scores_total ON mimiciv_derived.sofa2_scores(sofa2_total);

-- 添加表和列注释
COMMENT ON TABLE mimiciv_derived.sofa2_scores IS 'SOFA2评分系统结果表 - 基于JAMA 2025发表的Sequential Organ Failure Assessment 2.0
包含ICU住院期间每小时计算的SOFA2评分及24小时滚动窗口最差评分';

COMMENT ON COLUMN mimiciv_derived.sofa2_scores.stay_id IS 'ICU住院标识符';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.subject_id IS '患者标识符';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.hadm_id IS '住院标识符';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.hr IS 'ICU住院小时数（从0开始）';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.starttime IS '小时开始时间';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.endtime IS '小时结束时间';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.brain IS '神经系统评分（24小时窗口最差值，0-4分）';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.respiratory IS '呼吸系统评分（24小时窗口最差值，0-4分）';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.cardiovascular IS '心血管系统评分（24小时窗口最差值，0-4分）';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.liver IS '肝脏系统评分（24小时窗口最差值，0-4分）';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.kidney IS '肾脏系统评分（24小时窗口最差值，0-4分）';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.hemostasis IS '凝血系统评分（24小时窗口最差值，0-4分）';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.sofa2_total IS 'SOFA2总分（24小时窗口最差值，0-24分）';

-- 显示创建结果统计
SELECT
    'SOFA2评分表创建完成' AS status,
    COUNT(*) AS total_records,
    COUNT(DISTINCT stay_id) AS unique_stays,
    COUNT(DISTINCT subject_id) AS unique_patients,
    MIN(sofa2_total) AS min_score,
    MAX(sofa2_total) AS max_score,
    ROUND(AVG(sofa2_total), 2) AS avg_score
FROM mimiciv_derived.sofa2_scores;