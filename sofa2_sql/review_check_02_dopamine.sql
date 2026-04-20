-- Review Check #2: Dopamine sole vasopressor 条件检查
-- 找出 dopamine >20 且 NE=0, Epi=0, 但同时有其他血管活性药的情况
-- 这些情况下 dopamine 不是 sole vasopressor, score 3/4 可能不适用
WITH co AS (
    SELECT ih.stay_id, ih.hr,
           ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
    WHERE ih.hr BETWEEN 0 AND 23
),
cv_raw AS (
    SELECT co.stay_id, co.hr,
        MAX(va.norepinephrine) AS rate_nor,
        MAX(va.epinephrine) AS rate_epi,
        MAX(va.dopamine) AS rate_dop,
        MAX(va.dobutamine) AS rate_dob,
        MAX(va.vasopressin) AS rate_vas,
        MAX(va.phenylephrine) AS rate_phe,
        MAX(va.milrinone) AS rate_mil
    FROM co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
        AND co.endtime >= va.starttime + INTERVAL '1 HOUR'
    GROUP BY co.stay_id, co.hr
),
dop_cases AS (
    SELECT *,
        -- dopamine 是否为 sole vasopressor
        CASE WHEN (COALESCE(rate_dob,0) = 0 AND COALESCE(rate_vas,0) = 0 AND
                    COALESCE(rate_phe,0) = 0 AND COALESCE(rate_mil,0) = 0)
             THEN 1 ELSE 0 END AS dop_is_sole
    FROM cv_raw
    WHERE COALESCE(rate_dop, 0) > 20  -- 高剂量 dopamine
      AND COALESCE(rate_nor, 0) = 0   -- 无 NE
      AND COALESCE(rate_epi, 0) = 0   -- 无 Epi
)
SELECT
    COUNT(*) AS total_high_dop_hours,
    COUNT(DISTINCT stay_id) AS total_high_dop_stays,
    SUM(CASE WHEN dop_is_sole = 1 THEN 1 ELSE 0 END) AS sole_dop_hours,
    SUM(CASE WHEN dop_is_sole = 0 THEN 1 ELSE 0 END) AS nonsole_dop_hours,
    COUNT(DISTINCT CASE WHEN dop_is_sole = 0 THEN stay_id END) AS nonsole_dop_stays,
    -- 按剂量细分 nonsole 的情况
    SUM(CASE WHEN dop_is_sole = 0 AND rate_dop > 40 THEN 1 ELSE 0 END) AS nonsole_dop_gt40_hours,
    SUM(CASE WHEN dop_is_sole = 0 AND rate_dop > 20 AND rate_dop <= 40 THEN 1 ELSE 0 END) AS nonsole_dop_20to40_hours
FROM dop_cases;
