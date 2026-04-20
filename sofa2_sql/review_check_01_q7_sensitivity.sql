-- =================================================================
-- Query 7: 敏感性分析 — MAP-only 限制为最高1分 vs 当前逻辑
-- 比较对 first-day SOFA2 总分 和 脓毒症分类 的影响
-- =================================================================

WITH sepsis_stays AS (
    SELECT DISTINCT stay_id FROM (
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa1_delta
        UNION
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa2_delta
    ) t
),

-- 当前 first-day CV 最高分 (从已计算的表中取)
current_scores AS (
    SELECT
        stay_id,
        MAX(cardiovascular_score) AS cv_current
    FROM mimiciv_derived.sofa2_hourly_raw
    WHERE hr BETWEEN 0 AND 23
    GROUP BY stay_id
),

-- 重新计算: MAP-only 限制为最高1分的 CV 评分
co AS (
    SELECT ih.stay_id, ih.hr,
           ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
    INNER JOIN sepsis_stays ss ON ih.stay_id = ss.stay_id
    WHERE ih.hr BETWEEN 0 AND 23
),
cv_raw AS (
    SELECT co.stay_id, co.hr,
        MIN(vs.mbp) AS mbp_min,
        MAX(COALESCE(mech.is_ecmo, 0)) AS has_ecmo,
        MAX(COALESCE(mech.is_va_ecmo, 0)) AS has_va_ecmo,
        MAX(COALESCE(mech.is_vv_ecmo, 0)) AS has_vv_ecmo,
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
cv_restricted AS (
    SELECT stay_id, hr,
        CASE
            WHEN COALESCE(has_other_mech, 0) = 1 THEN 4
            WHEN COALESCE(has_va_ecmo, 0) = 1 THEN 4
            WHEN COALESCE(has_ecmo, 0) = 1 AND COALESCE(has_vv_ecmo, 0) = 0 THEN 4
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.4 THEN 4
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.2 AND other_drug = 1 THEN 4
            WHEN dop_score = 4 THEN 4
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0.2 THEN 3
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0 AND other_drug = 1 THEN 3
            WHEN dop_score = 3 THEN 3
            WHEN (COALESCE(rate_nor,0) + COALESCE(rate_epi,0)) > 0 THEN 2
            WHEN other_drug = 1 THEN 2
            WHEN dop_score = 2 THEN 2
            -- KEY CHANGE: MAP-only capped at 1
            WHEN COALESCE(mbp_min, 70) < 70 THEN 1
            ELSE 0
        END AS cv_restricted
    FROM (
        SELECT *,
            CASE WHEN rate_dop > 40 THEN 4 WHEN rate_dop > 20 THEN 3 WHEN rate_dop > 0 THEN 2 ELSE 0 END AS dop_score,
            CASE WHEN (COALESCE(rate_dob,0)>0 OR COALESCE(rate_vas,0)>0 OR COALESCE(rate_phe,0)>0 OR COALESCE(rate_mil,0)>0 OR COALESCE(rate_dop,0)>0)
                 THEN 1 ELSE 0 END AS other_drug
        FROM cv_raw
    ) x
),
restricted_max AS (
    SELECT stay_id, MAX(cv_restricted) AS cv_restricted
    FROM cv_restricted
    GROUP BY stay_id
),

-- 合并比较
comparison AS (
    SELECT
        cs.stay_id,
        COALESCE(c.cv_current, 0) AS cv_current,
        COALESCE(r.cv_restricted, 0) AS cv_restricted,
        COALESCE(c.cv_current, 0) - COALESCE(r.cv_restricted, 0) AS cv_diff
    FROM sepsis_stays cs
    LEFT JOIN current_scores c ON cs.stay_id = c.stay_id
    LEFT JOIN restricted_max r ON cs.stay_id = r.stay_id
)

-- Part A: 评分变化统计
SELECT
    'Part A: CV评分变化' AS label,
    COUNT(*) AS total,
    SUM(CASE WHEN cv_diff = 0 THEN 1 ELSE 0 END) AS unchanged,
    ROUND(100.0 * SUM(CASE WHEN cv_diff = 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_unchanged,
    SUM(CASE WHEN cv_diff > 0 THEN 1 ELSE 0 END) AS decreased,
    ROUND(100.0 * SUM(CASE WHEN cv_diff > 0 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_decreased,
    -- 按变化幅度细分
    SUM(CASE WHEN cv_diff = 1 THEN 1 ELSE 0 END) AS diff_1,
    SUM(CASE WHEN cv_diff = 2 THEN 1 ELSE 0 END) AS diff_2,
    SUM(CASE WHEN cv_diff = 3 THEN 1 ELSE 0 END) AS diff_3
FROM comparison;
