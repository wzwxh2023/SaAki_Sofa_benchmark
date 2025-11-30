-- =================================================================
-- Title: First Day SOFA-2 Score with Hybrid Calculation Method
-- Description:
-- This script calculates the first day SOFA-2 score using a hybrid approach.
-- For the KIDNEY score, it uses the robust "daily aggregation" method 
-- (worst value in 24h, scored once) to fix the score distribution issue.
-- For all OTHER scores, it continues to use the "max of hourly scores" method.
-- The final table is named `first_day_sofa2_daily`.
-- =================================================================

DROP TABLE IF EXISTS mimiciv_derived.first_day_sofa2_daily CASCADE;
CREATE TABLE mimiciv_derived.first_day_sofa2_daily AS

-- Step 1: Calculate the daily renal score using the robust aggregation method
WITH renal_aggs AS (
    SELECT
        ie.stay_id,
        -- get max creatinine from the first 24 hours (0-23)
        MAX(CASE WHEN kl.hr BETWEEN 0 AND 23 THEN kl.creatinine END) as creatinine_max,
        -- get total urine output from the first 24 hours (the value at hr=23)
        (SELECT u.uo_sum_24h FROM mimiciv_derived.sofa2_stage1_urine u WHERE u.stay_id = ie.stay_id AND u.hr = 23 LIMIT 1) AS urineoutput_24h,
        -- check if on RRT at any point in the first 24 hours
        MAX(CASE WHEN rrt.hr BETWEEN 0 AND 23 THEN rrt.on_rrt END) as on_rrt_first_day
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_derived.sofa2_stage1_kidney_labs kl ON ie.stay_id = kl.stay_id
    LEFT JOIN mimiciv_derived.sofa2_stage1_rrt rrt ON ie.stay_id = rrt.stay_id
    GROUP BY ie.stay_id
),
renal_daily_score AS (
    SELECT
        stay_id,
        -- Score the aggregated values once using classic daily SOFA thresholds
        CASE
            WHEN on_rrt_first_day = 1 THEN 4
            WHEN creatinine_max >= 5.0 THEN 4
            WHEN urineoutput_24h < 200 THEN 4
            WHEN creatinine_max >= 3.5 THEN 3
            WHEN urineoutput_24h < 500 THEN 3
            WHEN creatinine_max >= 2.0 THEN 2
            WHEN creatinine_max >= 1.2 THEN 1
            ELSE 0
        END AS kidney
    FROM renal_aggs
),

-- Step 2: Get the max of hourly scores for all other components
other_scores AS (
    SELECT
        stay_id,
        subject_id,
        hadm_id,
        MAX(brain) AS brain,
        MAX(respiratory) AS respiratory,
        MAX(cardiovascular) AS cardiovascular,
        MAX(liver) AS liver,
        MAX(hemostasis) AS hemostasis
    FROM mimiciv_derived.sofa2_scores_hr_filtered
    WHERE hr BETWEEN 0 AND 23
    GROUP BY stay_id, subject_id, hadm_id
)
-- Final Step: Join the robust kidney score with the other component scores
SELECT
    os.stay_id,
    os.subject_id,
    os.hadm_id,
    os.brain,
    os.respiratory,
    os.cardiovascular,
    os.liver,
    os.hemostasis,
    COALESCE(rds.kidney, 0) AS kidney, -- Use the new daily-aggregated kidney score
    (
        os.brain + 
        os.respiratory + 
        os.cardiovascular + 
        os.liver + 
        os.hemostasis + 
        COALESCE(rds.kidney, 0)
    ) as sofa2_total
FROM other_scores os
LEFT JOIN renal_daily_score rds ON os.stay_id = rds.stay_id;

-- Add indexes and comments
CREATE INDEX idx_first_day_sofa2_daily_stay ON mimiciv_derived.first_day_sofa2_daily(stay_id);
CREATE INDEX idx_first_day_sofa2_daily_subject ON mimiciv_derived.first_day_sofa2_daily(subject_id);
COMMENT ON TABLE mimiciv_derived.first_day_sofa2_daily IS 'First day SOFA-2 scores, calculated using a hybrid method: robust daily-aggregated kidney score and max-of-hourly for all other components.';
