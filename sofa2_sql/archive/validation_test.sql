-- Validation test for SOFA2 fixes
WITH 
co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id, hr, 
           ih.endtime - INTERVAL '1 HOUR' AS starttime, ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
    WHERE ih.stay_id IN (
        SELECT stay_id FROM mimiciv_derived.icustay_hourly 
        WHERE stay_id IS NOT NULL 
        ORDER BY stay_id 
        LIMIT 5
    )
    LIMIT 20
),
-- Test respiratory PF ratio with proper ventilation filtering
pf_test AS (
    SELECT
        ie.stay_id,
        bg.charttime,
        bg.pao2fio2ratio AS oxygen_ratio,
        CASE
            WHEN vd.stay_id IS NOT NULL THEN 1
            ELSE 0
        END AS has_advanced_support
    FROM mimiciv_derived.bg bg
    INNER JOIN mimiciv_icu.icustays ie ON ie.subject_id = bg.subject_id
    LEFT JOIN mimiciv_derived.ventilation vd
        ON ie.stay_id = vd.stay_id
        AND bg.charttime >= vd.starttime
        AND bg.charttime <= vd.endtime
        AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'Tracheostomy', 'HFNC')  -- Corrected: includes all advanced respiratory support
    WHERE bg.specimen = 'ART.'
      AND bg.pao2fio2ratio IS NOT NULL
      AND bg.pao2fio2ratio > 0
      AND ie.stay_id IN (SELECT stay_id FROM co)
),
-- Test cardiovascular dopamine grading
cardio_test AS (
    SELECT 
        co.stay_id,
        co.hr,
        0 AS brain,  -- placeholder
        -- Mock dopamine dosage for testing
        CASE 
            WHEN (co.stay_id % 4) = 0 THEN 0    -- No dopamine
            WHEN (co.stay_id % 4) = 1 THEN 15   -- <=20: 2 points
            WHEN (co.stay_id % 4) = 2 THEN 30   -- >20 <=40: 3 points  
            WHEN (co.stay_id % 4) = 3 THEN 50   -- >40: 4 points
        END AS dopamine_rate,
        -- Mock MAP for testing
        CASE WHEN (co.stay_id % 3) = 0 THEN 65 ELSE 75 END AS map_value
    FROM co
),
-- Test kidney without nested aggregation
kidney_test AS (
    SELECT
        co.stay_id,
        co.hr,
        -- Mock creatinine values
        CASE WHEN (co.stay_id % 5) = 0 THEN 1.0
             WHEN (co.stay_id % 5) = 1 THEN 1.5
             WHEN (co.stay_id % 5) = 2 THEN 2.5
             WHEN (co.stay_id % 5) = 3 THEN 4.0
             ELSE 0.9 END AS creatinine_max,
        -- Mock RRT status
        CASE WHEN (co.stay_id % 7) = 0 THEN 1 ELSE 0 END AS rrt_active_flag
    FROM co
),
-- Calculate scores
respiratory_score AS (
    SELECT 
        co.stay_id,
        co.hr,
        CASE 
            WHEN MIN(pf.oxygen_ratio) <= 75 AND MAX(pf.has_advanced_support) = 1 THEN 4
            WHEN MIN(pf.oxygen_ratio) <= 150 AND MAX(pf.has_advanced_support) = 1 THEN 3
            WHEN MIN(pf.oxygen_ratio) <= 225 THEN 2
            WHEN MIN(pf.oxygen_ratio) <= 300 THEN 1
            ELSE 0 
        END AS respiratory
    FROM co
    LEFT JOIN pf_test pf ON co.stay_id = pf.stay_id 
        AND pf.charttime >= co.starttime AND pf.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),
cardiovascular_score AS (
    SELECT
        stay_id,
        hr,
        CASE
            -- Test dopamine monotherapy grading (SOFA2 fix)
            WHEN dopamine_rate > 40 THEN 4
            WHEN dopamine_rate > 20 AND dopamine_rate <= 40 THEN 3
            WHEN dopamine_rate > 0 AND dopamine_rate <= 20 THEN 2
            -- Test MAP grading (SOFA2 fix)
            WHEN map_value < 40 AND dopamine_rate = 0 THEN 4
            WHEN map_value >= 40 AND map_value < 50 AND dopamine_rate = 0 THEN 3
            WHEN map_value >= 50 AND map_value < 60 AND dopamine_rate = 0 THEN 2
            WHEN map_value >= 60 AND map_value < 70 AND dopamine_rate = 0 THEN 1
            ELSE 0
        END AS cardiovascular
    FROM cardio_test
),
kidney_score AS (
    SELECT
        stay_id,
        hr,
        GREATEST(
            -- RRT-based score (no nested aggregation)
            CASE WHEN rrt_active_flag = 1 THEN 4 ELSE 0 END,
            -- Creatinine-based score (no nested aggregation)
            CASE
                WHEN creatinine_max > 3.5 THEN 3
                WHEN creatinine_max > 2.0 THEN 2
                WHEN creatinine_max > 1.2 THEN 1
                ELSE 0
            END
        ) AS kidney
    FROM kidney_test
)
-- Final results
SELECT 
    co.stay_id,
    co.hr,
    0 AS brain,  -- placeholder
    COALESCE(resp.respiratory, 0) AS respiratory,
    COALESCE(card.cardiovascular, 0) AS cardiovascular,
    0 AS liver,  -- placeholder
    COALESCE(kid.kidney, 0) AS kidney,
    0 AS hemostasis,  -- placeholder
    COALESCE(resp.respiratory, 0) + COALESCE(card.cardiovascular, 0) + COALESCE(kid.kidney, 0) AS sofa2_total
FROM co
LEFT JOIN respiratory_score resp ON co.stay_id = resp.stay_id AND co.hr = resp.hr
LEFT JOIN cardiovascular_score card ON co.stay_id = card.stay_id AND co.hr = card.hr
LEFT JOIN kidney_score kid ON co.stay_id = kid.stay_id AND co.hr = kid.hr
ORDER BY co.stay_id, co.hr
LIMIT 10;
