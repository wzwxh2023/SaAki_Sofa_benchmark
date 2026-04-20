-- Query 4: MAP-only 是否真正改变了 first-day 最终 CV 最高分
WITH co AS (
    SELECT ih.stay_id, ih.hr,
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
hourly_classified AS (
    SELECT stay_id, hr, mbp_min,
        CASE WHEN (
            COALESCE(rate_nor,0) > 0 OR COALESCE(rate_epi,0) > 0 OR
            COALESCE(rate_dop,0) > 0 OR COALESCE(rate_dob,0) > 0 OR
            COALESCE(rate_vas,0) > 0 OR COALESCE(rate_phe,0) > 0 OR
            COALESCE(rate_mil,0) > 0 OR
            COALESCE(has_ecmo,0) = 1 OR COALESCE(has_other_mech,0) = 1
        ) THEN 1 ELSE 0 END AS has_support,
        CASE
            WHEN mbp_min IS NULL THEN 0
            WHEN mbp_min < 40 THEN 4
            WHEN mbp_min < 50 THEN 3
            WHEN mbp_min < 60 THEN 2
            WHEN mbp_min < 70 THEN 1
            ELSE 0
        END AS map_only_score
    FROM cv_raw
),
per_stay AS (
    SELECT stay_id,
        MAX(CASE WHEN has_support = 0 THEN map_only_score ELSE 0 END) AS max_map_only_score,
        MAX(CASE WHEN has_support = 1 THEN 1 ELSE 0 END) AS ever_had_support
    FROM hourly_classified
    GROUP BY stay_id
)
SELECT
    COUNT(*) AS total_stays,
    SUM(CASE WHEN max_map_only_score >= 2 AND ever_had_support = 0 THEN 1 ELSE 0 END)
        AS pure_map_only_ge2,
    SUM(CASE WHEN max_map_only_score >= 2 AND ever_had_support = 1 THEN 1 ELSE 0 END)
        AS map_ge2_but_also_had_support,
    SUM(CASE WHEN max_map_only_score = 2 AND ever_had_support = 0 THEN 1 ELSE 0 END) AS pure_score2,
    SUM(CASE WHEN max_map_only_score = 3 AND ever_had_support = 0 THEN 1 ELSE 0 END) AS pure_score3,
    SUM(CASE WHEN max_map_only_score = 4 AND ever_had_support = 0 THEN 1 ELSE 0 END) AS pure_score4
FROM per_stay;
