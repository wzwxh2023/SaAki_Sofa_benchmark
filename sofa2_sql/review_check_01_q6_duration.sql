-- Query 6: 脓毒症队列中, 纯MAP-only score>=2 的持续时间分布
-- 这些患者有多少个小时处于 "无升压药 + MAP<60" 的状态?
WITH sepsis_stays AS (
    SELECT DISTINCT stay_id FROM (
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa1_delta
        UNION
        SELECT stay_id FROM mimiciv_derived.sepsis3_sofa2_delta
    ) t
),
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
affected_hours AS (
    SELECT stay_id, hr, mbp_min
    FROM cv_raw
    WHERE (COALESCE(rate_nor,0) = 0 AND COALESCE(rate_epi,0) = 0 AND
           COALESCE(rate_dop,0) = 0 AND COALESCE(rate_dob,0) = 0 AND
           COALESCE(rate_vas,0) = 0 AND COALESCE(rate_phe,0) = 0 AND
           COALESCE(rate_mil,0) = 0)
      AND (COALESCE(has_ecmo,0) = 0 AND COALESCE(has_other_mech,0) = 0)
      AND mbp_min IS NOT NULL AND mbp_min < 60
),
per_stay_hours AS (
    SELECT stay_id,
        COUNT(*) AS hours_affected,
        MIN(mbp_min) AS lowest_map,
        ROUND(AVG(mbp_min)::numeric, 1) AS avg_map
    FROM affected_hours
    GROUP BY stay_id
)
SELECT
    CASE
        WHEN hours_affected = 1 THEN '1h (一过性)'
        WHEN hours_affected BETWEEN 2 AND 3 THEN '2-3h'
        WHEN hours_affected BETWEEN 4 AND 6 THEN '4-6h'
        WHEN hours_affected BETWEEN 7 AND 12 THEN '7-12h'
        WHEN hours_affected > 12 THEN '>12h (持续性)'
    END AS duration_group,
    COUNT(*) AS stays,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 1) AS pct,
    ROUND(AVG(lowest_map)::numeric, 1) AS avg_lowest_map,
    ROUND(AVG(avg_map)::numeric, 1) AS avg_mean_map
FROM per_stay_hours
GROUP BY
    CASE
        WHEN hours_affected = 1 THEN '1h (一过性)'
        WHEN hours_affected BETWEEN 2 AND 3 THEN '2-3h'
        WHEN hours_affected BETWEEN 4 AND 6 THEN '4-6h'
        WHEN hours_affected BETWEEN 7 AND 12 THEN '7-12h'
        WHEN hours_affected > 12 THEN '>12h (持续性)'
    END
ORDER BY MIN(hours_affected);
