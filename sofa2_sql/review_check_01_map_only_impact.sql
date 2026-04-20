-- =================================================================
-- 审稿核查 #1: MAP-only 评分的影响范围分析
--
-- 背景：R#2 质疑 MAP 单独可以打 ≥2 分
-- 原文依据：SOFA-2 Table 3 脚注明确规定 ceiling-of-treatment 场景
--   使用 MAP cutoff 可打 0-4 分
-- 目的：用数据说明受影响的规模和合理性
-- =================================================================

-- -------------------------------------------------------
-- Query 1: 患者级别 — first-day (hr 0-23) 内
--   "无血管活性药 + 无机械支持 + MAP<60" 的 stay 数
-- -------------------------------------------------------
WITH co AS (
    SELECT ih.stay_id, ie.subject_id, ih.hr,
           ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 23
),
cv_raw AS (
    SELECT co.stay_id, co.subject_id, co.hr,
        MIN(vs.mbp) AS mbp_min,
        MAX(COALESCE(mech.is_ecmo, 0)) AS has_ecmo,
        MAX(COALESCE(mech.is_other_mech, 0)) AS has_other_mech,
        MAX(va.norepinephrine) AS rate_nor,
        MAX(va.epinephrine) AS rate_epi,
        MAX(va.dopamine) AS rate_dop,
        MAX(va.dobutamine) AS rate_dob,
        MAX(va.vasopressin) AS rate_vas,
        MAX(va.phenylephrine) AS rate_phe,
        MAX(va.milrinone) AS rate_mil
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_mech mech
        ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN mimiciv_derived.vitalsign vs
        ON co.stay_id = vs.stay_id AND vs.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
        AND co.endtime >= va.starttime + INTERVAL '1 HOUR'
    GROUP BY co.stay_id, co.subject_id, co.hr
),
flagged AS (
    SELECT *,
        CASE WHEN (
            COALESCE(rate_nor,0) > 0 OR COALESCE(rate_epi,0) > 0 OR
            COALESCE(rate_dop,0) > 0 OR COALESCE(rate_dob,0) > 0 OR
            COALESCE(rate_vas,0) > 0 OR COALESCE(rate_phe,0) > 0 OR
            COALESCE(rate_mil,0) > 0
        ) THEN 1 ELSE 0 END AS has_any_vaso,
        CASE WHEN (COALESCE(has_ecmo,0) = 1 OR COALESCE(has_other_mech,0) = 1)
             THEN 1 ELSE 0 END AS has_mech
    FROM cv_raw
),
-- 找出受影响的 stay（至少有一个小时满足条件）
affected_stays AS (
    SELECT DISTINCT stay_id, subject_id
    FROM flagged
    WHERE has_any_vaso = 0 AND has_mech = 0
      AND mbp_min IS NOT NULL AND mbp_min < 60
)
SELECT
    'Query 1: 患者级别统计' AS label,
    (SELECT COUNT(DISTINCT stay_id) FROM co) AS total_stays,
    COUNT(DISTINCT a.stay_id) AS affected_stays,
    COUNT(DISTINCT a.subject_id) AS affected_patients,
    ROUND(100.0 * COUNT(DISTINCT a.stay_id) /
          NULLIF((SELECT COUNT(DISTINCT stay_id) FROM co), 0), 2) AS pct
FROM affected_stays a;


-- -------------------------------------------------------
-- Query 2: 受影响患者的 MAP 分布（按评分区间）
--   无血管活性药 + 无机械支持时，MAP 最低值落在哪个区间
-- -------------------------------------------------------
WITH co AS (
    SELECT ih.stay_id, ie.subject_id, ih.hr,
           ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 23
),
cv_raw AS (
    SELECT co.stay_id, co.subject_id, co.hr,
        MIN(vs.mbp) AS mbp_min,
        MAX(COALESCE(mech.is_ecmo, 0)) AS has_ecmo,
        MAX(COALESCE(mech.is_other_mech, 0)) AS has_other_mech,
        MAX(va.norepinephrine) AS rate_nor,
        MAX(va.epinephrine) AS rate_epi,
        MAX(va.dopamine) AS rate_dop,
        MAX(va.dobutamine) AS rate_dob,
        MAX(va.vasopressin) AS rate_vas,
        MAX(va.phenylephrine) AS rate_phe,
        MAX(va.milrinone) AS rate_mil
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_mech mech
        ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN mimiciv_derived.vitalsign vs
        ON co.stay_id = vs.stay_id AND vs.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
        AND co.endtime >= va.starttime + INTERVAL '1 HOUR'
    GROUP BY co.stay_id, co.subject_id, co.hr
),
no_vaso_low_map AS (
    SELECT stay_id, hr, mbp_min,
        CASE
            WHEN mbp_min < 40 THEN 'MAP<40 (score 4)'
            WHEN mbp_min < 50 THEN 'MAP 40-49 (score 3)'
            WHEN mbp_min < 60 THEN 'MAP 50-59 (score 2)'
        END AS map_band
    FROM cv_raw
    WHERE (COALESCE(rate_nor,0) = 0 AND COALESCE(rate_epi,0) = 0 AND
           COALESCE(rate_dop,0) = 0 AND COALESCE(rate_dob,0) = 0 AND
           COALESCE(rate_vas,0) = 0 AND COALESCE(rate_phe,0) = 0 AND
           COALESCE(rate_mil,0) = 0)
      AND (COALESCE(has_ecmo,0) = 0 AND COALESCE(has_other_mech,0) = 0)
      AND mbp_min IS NOT NULL AND mbp_min < 60
)
SELECT
    'Query 2: MAP分布' AS label,
    map_band,
    COUNT(*) AS affected_hours,
    COUNT(DISTINCT stay_id) AS affected_stays
FROM no_vaso_low_map
GROUP BY map_band
ORDER BY map_band;


-- -------------------------------------------------------
-- Query 3: 这些患者是否在"之后的小时"用上了血管活性药？
--   （支持 "记录延迟 / 即将启动升压" 的推断）
-- -------------------------------------------------------
WITH co AS (
    SELECT ih.stay_id, ie.subject_id, ih.hr,
           ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 23
),
cv_raw AS (
    SELECT co.stay_id, co.hr,
        MIN(vs.mbp) AS mbp_min,
        MAX(COALESCE(mech.is_ecmo, 0)) AS has_ecmo,
        MAX(COALESCE(mech.is_other_mech, 0)) AS has_other_mech,
        MAX(va.norepinephrine) AS rate_nor,
        MAX(va.epinephrine) AS rate_epi,
        MAX(va.dopamine) AS rate_dop,
        MAX(va.dobutamine) AS rate_dob,
        MAX(va.vasopressin) AS rate_vas,
        MAX(va.phenylephrine) AS rate_phe,
        MAX(va.milrinone) AS rate_mil
    FROM co
    LEFT JOIN mimiciv_derived.sofa2_stage1_mech mech
        ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN mimiciv_derived.vitalsign vs
        ON co.stay_id = vs.stay_id AND vs.charttime BETWEEN co.starttime AND co.endtime
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
        AND co.endtime >= va.starttime + INTERVAL '1 HOUR'
    GROUP BY co.stay_id, co.hr
),
-- 受影响的 stay
affected AS (
    SELECT DISTINCT stay_id
    FROM cv_raw
    WHERE (COALESCE(rate_nor,0) = 0 AND COALESCE(rate_epi,0) = 0 AND
           COALESCE(rate_dop,0) = 0 AND COALESCE(rate_dob,0) = 0 AND
           COALESCE(rate_vas,0) = 0 AND COALESCE(rate_phe,0) = 0 AND
           COALESCE(rate_mil,0) = 0)
      AND (COALESCE(has_ecmo,0) = 0 AND COALESCE(has_other_mech,0) = 0)
      AND mbp_min IS NOT NULL AND mbp_min < 60
),
-- 这些患者在整个 ICU stay 期间是否用过血管活性药
ever_vaso AS (
    SELECT DISTINCT a.stay_id,
        CASE WHEN va.stay_id IS NOT NULL THEN 1 ELSE 0 END AS used_vaso_later
    FROM affected a
    LEFT JOIN mimiciv_derived.vasoactive_agent va ON a.stay_id = va.stay_id
)
SELECT
    'Query 3: 后续用药情况' AS label,
    COUNT(*) AS total_affected_stays,
    SUM(used_vaso_later) AS later_used_vaso,
    SUM(CASE WHEN used_vaso_later = 0 THEN 1 ELSE 0 END) AS never_used_vaso,
    ROUND(100.0 * SUM(used_vaso_later) / NULLIF(COUNT(*), 0), 1) AS pct_later_used
FROM ever_vaso;
