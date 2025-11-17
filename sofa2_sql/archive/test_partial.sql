, drug_params AS (
    SELECT
        -- Sedation/analgesia drugs (common ICU sedatives)
        ARRAY['%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
              '%fentanyl%', '%remifentanil%', '%morphine%', '%hydromorphone%',
              '%dexmedetomidine%', '%ketamine%', '%clonidine%', '%etomidate%'] AS sedation_patterns,
        -- Delirium drugs (antipsychotics for delirium control)
        ARRAY['%haloperidol%', '%haldol%', '%quetiapine%', '%seroquel%',
              '%olanzapine%', '%zyprexa%', '%risperidone%', '%risperdal%',
              '%ziprasidone%', '%geodon%', '%clozapine%', '%aripiprazole%'] AS delirium_patterns
),

-- Step 2: Preprocess all GCS measurements, including data cleaning and sedation status
, gcs_stg AS (
    SELECT
        gcs.stay_id,
        gcs.charttime,
        -- GCS data cleaning: handle abnormal values
        CASE
            WHEN gcs.gcs < 3 THEN 3
            WHEN gcs.gcs > 15 THEN 15
            ELSE gcs.gcs
        END AS gcs,
        -- Determine if sedation drugs are being infused at GCS measurement time
        MAX(CASE
            WHEN pr.starttime <= gcs.charttime
                 AND COALESCE(pr.stoptime, gcs.charttime + INTERVAL '1 minute') > gcs.charttime
                 AND LOWER(pr.drug) ILIKE ANY (SELECT sedation_patterns FROM drug_params)
            THEN 1 ELSE 0
        END) AS is_sedated
    FROM mimiciv_derived.gcs gcs
    -- Pre-join with icustays and prescriptions to avoid duplication in LATERAL
    INNER JOIN mimiciv_icu.icustays ie ON gcs.stay_id = ie.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE gcs.gcs IS NOT NULL
    GROUP BY gcs.stay_id, gcs.charttime, gcs.gcs
),

-- Step 3: Preprocess hourly delirium drug usage
, delirium_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE
            WHEN pr.starttime <= co.endtime
                 AND COALESCE(pr.stoptime, co.endtime) >= co.starttime
                 AND LOWER(pr.drug) ILIKE ANY (SELECT delirium_patterns FROM drug_params)
            THEN 1 ELSE 0
        END) AS on_delirium_med
    FROM co
    INNER JOIN mimiciv_icu.icustays ie ON co.stay_id = ie.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- BRAIN/Nervous System (Integrated version: performance optimized + clear logic)
-- =================================================================
, gcs AS (
    SELECT
        co.stay_id,
        co.hr,
        gcs_vals.gcs,
        -- GREATEST function: clearly express "take maximum" semantics + handle missing values
        GREATEST(
            -- Score source 1: GCS score (missing values default to 0 points)
            CASE
                WHEN gcs_vals.gcs IS NULL THEN 0
                WHEN gcs_vals.gcs <= 5  THEN 4
                WHEN gcs_vals.gcs <= 8  THEN 3  -- GCS 6-8
                WHEN gcs_vals.gcs <= 12 THEN 2  -- GCS 9-12
                WHEN gcs_vals.gcs <= 14 THEN 1  -- GCS 13-14
                ELSE 0  -- GCS 15
            END,
            -- Score source 2: Delirium drugs (SOFA2 standard: any delirium drug gets at least 1 point)
            CASE WHEN d.on_delirium_med = 1 THEN 1 ELSE 0 END
        ) AS brain
    FROM co
    -- Efficient LATERAL: find from preprocessed GCS table
    LEFT JOIN LATERAL (
