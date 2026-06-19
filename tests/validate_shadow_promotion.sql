-- Validate a shadow SOFA-2 rebuild before promotion.
--
-- Required psql variable:
--   -v shadow_schema=sofa_gov_20260619_rebuild_v1
--
-- Core invariant: first-day SOFA-2 total must be SUM(per-organ first-day maxima),
-- never MAX(hourly total).

\set ON_ERROR_STOP on

\if :{?shadow_schema}
\else
  \echo 'shadow_schema variable is required'
  DO $$ BEGIN RAISE EXCEPTION 'shadow_schema variable is required'; END $$;
\endif

SELECT set_config(
    'app.shadow_schema',
    :'shadow_schema',
    false
);

DO $$
BEGIN
    IF current_setting('app.shadow_schema') = 'mimiciv_derived' THEN
        RAISE EXCEPTION 'Refusing to validate with production schema mimiciv_derived as shadow_schema';
    END IF;
END $$;

SELECT set_config(
    'search_path',
    quote_ident(:'shadow_schema') || ', mimiciv_derived, mimiciv_team, mimiciv_icu, mimiciv_hosp, public',
    false
);

\echo 'Validation: required shadow objects'

DO $$
DECLARE
    shadow_schema text := current_setting('app.shadow_schema');
    required_object text;
BEGIN
    FOREACH required_object IN ARRAY ARRAY[
        'sofa2_scores_hr_filtered',
        'first_day_sofa2',
        'sepsis3_sofa2_delta',
        'sepsis3_sofa1_delta',
        'patient_outcomes'
    ]
    LOOP
        IF to_regclass(format('%I.%I', shadow_schema, required_object)) IS NULL THEN
            RAISE EXCEPTION 'Missing required shadow object: %.%', shadow_schema, required_object;
        END IF;
    END LOOP;
END $$;

\echo 'Validation: row counts'

DO $$
DECLARE
    row_n bigint;
    stay_n bigint;
BEGIN
    SELECT COUNT(DISTINCT stay_id) INTO stay_n
    FROM sofa2_scores_hr_filtered;
    IF stay_n <> 94458 THEN
        RAISE EXCEPTION 'shadow sofa2_scores_hr_filtered stay count %, expected 94458', stay_n;
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT stay_id) INTO row_n, stay_n
    FROM first_day_sofa2;
    IF row_n <> 94458 OR stay_n <> 94458 THEN
        RAISE EXCEPTION 'shadow first_day_sofa2 rows/stays %/%, expected 94458/94458', row_n, stay_n;
    END IF;

    SELECT COUNT(*), COUNT(DISTINCT stay_id) INTO row_n, stay_n
    FROM patient_outcomes;
    IF row_n <> 94458 OR stay_n <> 94458 THEN
        RAISE EXCEPTION 'shadow patient_outcomes rows/stays %/%, expected 94458/94458', row_n, stay_n;
    END IF;
END $$;

\echo 'Validation: first-day organ maxima and total invariants'

DO $$
DECLARE
    mismatch_n bigint;
BEGIN
    WITH recompute AS (
        SELECT
            stay_id,
            MAX(brain) AS brain,
            MAX(respiratory) AS respiratory,
            MAX(cardiovascular) AS cardiovascular,
            MAX(kidney) AS kidney,
            MAX(liver_lab48_rescue) AS liver_lab48_rescue,
            MAX(hemostasis_lab48_rescue) AS hemostasis_lab48_rescue,
            MAX(liver_strict24) AS liver_strict24,
            MAX(hemostasis_strict24) AS hemostasis_strict24,
            MAX(liver_full48_exploratory) AS liver_full48_exploratory,
            MAX(hemostasis_full48_exploratory) AS hemostasis_full48_exploratory
        FROM sofa2_scores_hr_filtered
        WHERE hr BETWEEN 0 AND 23
        GROUP BY stay_id
    ),
    expected AS (
        SELECT
            stay_id,
            COALESCE(brain, 0) AS brain,
            COALESCE(respiratory, 0) AS respiratory,
            COALESCE(cardiovascular, 0) AS cardiovascular,
            COALESCE(kidney, 0) AS kidney,
            COALESCE(liver_lab48_rescue, 0) AS liver_lab48_rescue,
            COALESCE(hemostasis_lab48_rescue, 0) AS hemostasis_lab48_rescue,
            COALESCE(liver_strict24, 0) AS liver_strict24,
            COALESCE(hemostasis_strict24, 0) AS hemostasis_strict24,
            COALESCE(liver_full48_exploratory, 0) AS liver_full48_exploratory,
            COALESCE(hemostasis_full48_exploratory, 0) AS hemostasis_full48_exploratory,
            COALESCE(brain, 0) + COALESCE(respiratory, 0)
                + COALESCE(cardiovascular, 0) + COALESCE(kidney, 0)
                + COALESCE(liver_lab48_rescue, 0) + COALESCE(hemostasis_lab48_rescue, 0) AS sofa2_total_lab48_rescue,
            COALESCE(brain, 0) + COALESCE(respiratory, 0)
                + COALESCE(cardiovascular, 0) + COALESCE(kidney, 0)
                + COALESCE(liver_strict24, 0) + COALESCE(hemostasis_strict24, 0) AS sofa2_total_strict24,
            COALESCE(brain, 0) + COALESCE(respiratory, 0)
                + COALESCE(cardiovascular, 0) + COALESCE(kidney, 0)
                + COALESCE(liver_full48_exploratory, 0) + COALESCE(hemostasis_full48_exploratory, 0) AS sofa2_total_full48_exploratory
        FROM recompute
    ),
    mismatches AS (
        SELECT COALESCE(f.stay_id, e.stay_id) AS stay_id
        FROM first_day_sofa2 f
        FULL JOIN expected e USING (stay_id)
        WHERE f.stay_id IS NULL
           OR e.stay_id IS NULL
           OR f.brain IS DISTINCT FROM e.brain
           OR f.respiratory IS DISTINCT FROM e.respiratory
           OR f.cardiovascular IS DISTINCT FROM e.cardiovascular
           OR f.kidney IS DISTINCT FROM e.kidney
           OR f.liver_lab48_rescue IS DISTINCT FROM e.liver_lab48_rescue
           OR f.hemostasis_lab48_rescue IS DISTINCT FROM e.hemostasis_lab48_rescue
           OR f.liver_strict24 IS DISTINCT FROM e.liver_strict24
           OR f.hemostasis_strict24 IS DISTINCT FROM e.hemostasis_strict24
           OR f.liver_full48_exploratory IS DISTINCT FROM e.liver_full48_exploratory
           OR f.hemostasis_full48_exploratory IS DISTINCT FROM e.hemostasis_full48_exploratory
           OR f.sofa2_total_lab48_rescue IS DISTINCT FROM e.sofa2_total_lab48_rescue
           OR f.sofa2_total_strict24 IS DISTINCT FROM e.sofa2_total_strict24
           OR f.sofa2_total_full48_exploratory IS DISTINCT FROM e.sofa2_total_full48_exploratory
    )
    SELECT COUNT(*) INTO mismatch_n
    FROM mismatches;

    IF mismatch_n <> 0 THEN
        RAISE EXCEPTION 'first-day component/total invariant mismatches: %', mismatch_n;
    END IF;
END $$;

\echo 'Validation: SOFA-2 delta sepsis recomputation'

DO $$
DECLARE
    mismatch_n bigint;
BEGIN
    WITH soi AS (
        SELECT
            subject_id,
            stay_id,
            hadm_id,
            ab_id,
            antibiotic,
            antibiotic_time,
            culture_time,
            suspected_infection,
            suspected_infection_time,
            specimen,
            positive_culture
        FROM mimiciv_derived.suspicion_of_infection
        WHERE stay_id IS NOT NULL
    ),
    sofa2 AS (
        SELECT
            stay_id,
            starttime,
            endtime,
            brain,
            respiratory,
            cardiovascular,
            liver,
            kidney,
            hemostasis,
            sofa2_total AS sofa2_score
        FROM sofa2_scores_hr_filtered
    ),
    baseline AS (
        SELECT
            soi.subject_id,
            soi.stay_id,
            soi.hadm_id,
            soi.suspected_infection_time,
            MIN(s2.sofa2_score) AS baseline_sofa2,
            COUNT(*) > 0 AS baseline_observed
        FROM soi
        LEFT JOIN sofa2 s2
            ON soi.stay_id = s2.stay_id
           AND s2.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
           AND s2.endtime <  soi.suspected_infection_time
        GROUP BY soi.subject_id, soi.stay_id, soi.hadm_id, soi.suspected_infection_time
    ),
    window_scores AS (
        SELECT
            soi.subject_id,
            soi.stay_id,
            soi.hadm_id,
            soi.ab_id,
            soi.antibiotic,
            soi.antibiotic_time,
            soi.culture_time,
            soi.suspected_infection_time,
            s2.endtime AS sofa_time,
            s2.sofa2_score,
            s2.brain,
            s2.respiratory,
            s2.cardiovascular,
            s2.liver,
            s2.kidney,
            s2.hemostasis,
            COALESCE(baseline.baseline_sofa2, 0) AS baseline_sofa2,
            baseline.baseline_observed,
            s2.sofa2_score - COALESCE(baseline.baseline_sofa2, 0) AS delta_sofa2,
            (s2.sofa2_score - COALESCE(baseline.baseline_sofa2, 0) >= 2 AND soi.suspected_infection = 1) AS sepsis3_sofa2_delta
        FROM soi
        INNER JOIN sofa2 s2
            ON soi.stay_id = s2.stay_id
           AND s2.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
           AND s2.endtime <= soi.suspected_infection_time + INTERVAL '24 hours'
        LEFT JOIN baseline
            ON soi.stay_id = baseline.stay_id
           AND soi.subject_id = baseline.subject_id
           AND soi.hadm_id = baseline.hadm_id
           AND soi.suspected_infection_time = baseline.suspected_infection_time
    ),
    expected AS (
        SELECT *
        FROM (
            SELECT
                ws.*,
                ROW_NUMBER() OVER (
                    PARTITION BY ws.stay_id
                    ORDER BY ws.suspected_infection_time, ws.antibiotic_time, ws.culture_time, ws.sofa_time
                ) AS rn
            FROM window_scores ws
            WHERE ws.sepsis3_sofa2_delta
        ) ranked
        WHERE rn = 1
    ),
    mismatches AS (
        SELECT COALESCE(a.stay_id, e.stay_id) AS stay_id
        FROM sepsis3_sofa2_delta a
        FULL JOIN expected e USING (stay_id)
        WHERE a.stay_id IS NULL
           OR e.stay_id IS NULL
           OR a.subject_id IS DISTINCT FROM e.subject_id
           OR a.hadm_id IS DISTINCT FROM e.hadm_id
           OR a.ab_id IS DISTINCT FROM e.ab_id
           OR a.antibiotic_time IS DISTINCT FROM e.antibiotic_time
           OR a.culture_time IS DISTINCT FROM e.culture_time
           OR a.suspected_infection_time IS DISTINCT FROM e.suspected_infection_time
           OR a.sofa_time IS DISTINCT FROM e.sofa_time
           OR a.sofa2_score IS DISTINCT FROM e.sofa2_score
           OR a.baseline_sofa2 IS DISTINCT FROM e.baseline_sofa2
           OR a.baseline_observed IS DISTINCT FROM e.baseline_observed
           OR a.delta_sofa2 IS DISTINCT FROM e.delta_sofa2
           OR a.sepsis3_sofa2_delta IS DISTINCT FROM e.sepsis3_sofa2_delta
    )
    SELECT COUNT(*) INTO mismatch_n
    FROM mismatches;

    IF mismatch_n <> 0 THEN
        RAISE EXCEPTION 'SOFA-2 delta sepsis recomputation mismatches: %', mismatch_n;
    END IF;
END $$;

\echo 'Validation: SOFA-1 delta sepsis recomputation'

DO $$
DECLARE
    mismatch_n bigint;
BEGIN
    WITH soi AS (
        SELECT
            subject_id,
            stay_id,
            hadm_id,
            ab_id,
            antibiotic,
            antibiotic_time,
            culture_time,
            suspected_infection,
            suspected_infection_time,
            specimen,
            positive_culture
        FROM mimiciv_derived.suspicion_of_infection
        WHERE stay_id IS NOT NULL
    ),
    sofa AS (
        SELECT
            stay_id,
            starttime,
            endtime,
            sofa_respiration_official_mimic_hourly AS respiration,
            sofa_coagulation_official_mimic_hourly AS coagulation,
            sofa_liver_official_mimic_hourly AS liver,
            sofa_cardiovascular_official_mimic_hourly AS cardiovascular,
            sofa_cns_official_mimic_hourly AS cns,
            sofa_renal_official_mimic_hourly AS renal,
            "SOFA" AS sofa_score
        FROM mimiciv_derived.sofa1_hourly_current
    ),
    baseline AS (
        SELECT
            soi.subject_id,
            soi.stay_id,
            soi.hadm_id,
            soi.suspected_infection_time,
            MIN(s.sofa_score) AS baseline_sofa,
            COUNT(*) > 0 AS baseline_observed
        FROM soi
        LEFT JOIN sofa s
            ON soi.stay_id = s.stay_id
           AND s.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
           AND s.endtime <  soi.suspected_infection_time
        GROUP BY soi.subject_id, soi.stay_id, soi.hadm_id, soi.suspected_infection_time
    ),
    window_scores AS (
        SELECT
            soi.subject_id,
            soi.stay_id,
            soi.hadm_id,
            soi.ab_id,
            soi.antibiotic,
            soi.antibiotic_time,
            soi.culture_time,
            soi.suspected_infection_time,
            s.endtime AS sofa_time,
            s.sofa_score,
            s.respiration,
            s.coagulation,
            s.liver,
            s.cardiovascular,
            s.cns,
            s.renal,
            COALESCE(baseline.baseline_sofa, 0) AS baseline_sofa,
            baseline.baseline_observed,
            s.sofa_score - COALESCE(baseline.baseline_sofa, 0) AS delta_sofa,
            (s.sofa_score - COALESCE(baseline.baseline_sofa, 0) >= 2 AND soi.suspected_infection = 1) AS sepsis3_sofa1_delta
        FROM soi
        INNER JOIN sofa s
            ON soi.stay_id = s.stay_id
           AND s.endtime >= soi.suspected_infection_time - INTERVAL '48 hours'
           AND s.endtime <= soi.suspected_infection_time + INTERVAL '24 hours'
        LEFT JOIN baseline
            ON soi.stay_id = baseline.stay_id
           AND soi.subject_id = baseline.subject_id
           AND soi.hadm_id = baseline.hadm_id
           AND soi.suspected_infection_time = baseline.suspected_infection_time
    ),
    expected AS (
        SELECT *
        FROM (
            SELECT
                ws.*,
                ROW_NUMBER() OVER (
                    PARTITION BY ws.stay_id
                    ORDER BY ws.suspected_infection_time, ws.antibiotic_time, ws.culture_time, ws.sofa_time
                ) AS rn
            FROM window_scores ws
            WHERE ws.sepsis3_sofa1_delta
        ) ranked
        WHERE rn = 1
    ),
    mismatches AS (
        SELECT COALESCE(a.stay_id, e.stay_id) AS stay_id
        FROM sepsis3_sofa1_delta a
        FULL JOIN expected e USING (stay_id)
        WHERE a.stay_id IS NULL
           OR e.stay_id IS NULL
           OR a.subject_id IS DISTINCT FROM e.subject_id
           OR a.hadm_id IS DISTINCT FROM e.hadm_id
           OR a.ab_id IS DISTINCT FROM e.ab_id
           OR a.antibiotic_time IS DISTINCT FROM e.antibiotic_time
           OR a.culture_time IS DISTINCT FROM e.culture_time
           OR a.suspected_infection_time IS DISTINCT FROM e.suspected_infection_time
           OR a.sofa_time IS DISTINCT FROM e.sofa_time
           OR a.sofa_score IS DISTINCT FROM e.sofa_score
           OR a.baseline_sofa IS DISTINCT FROM e.baseline_sofa
           OR a.baseline_observed IS DISTINCT FROM e.baseline_observed
           OR a.delta_sofa IS DISTINCT FROM e.delta_sofa
           OR a.sepsis3_sofa1_delta IS DISTINCT FROM e.sepsis3_sofa1_delta
    )
    SELECT COUNT(*) INTO mismatch_n
    FROM mismatches;

    IF mismatch_n <> 0 THEN
        RAISE EXCEPTION 'SOFA-1 delta sepsis recomputation mismatches: %', mismatch_n;
    END IF;
END $$;

\echo 'Validation: sepsis definition table matches shadow delta tables'

DO $$
DECLARE
    mismatch_n bigint;
BEGIN
    SELECT COUNT(*) INTO mismatch_n
    FROM sepsis3_definitions_current d
    LEFT JOIN mimiciv_derived.sepsis3 off ON d.stay_id = off.stay_id
    LEFT JOIN sepsis3_sofa1_delta s1 ON d.stay_id = s1.stay_id
    LEFT JOIN sepsis3_sofa2_delta s2 ON d.stay_id = s2.stay_id
    WHERE d.sepsis3_sofa1_official_absolute IS DISTINCT FROM CASE WHEN off.sepsis3 = true THEN 1 ELSE 0 END
       OR d.sepsis3_sofa1_delta IS DISTINCT FROM CASE WHEN s1.sepsis3_sofa1_delta = true THEN 1 ELSE 0 END
       OR d.sepsis3_sofa2_delta IS DISTINCT FROM CASE WHEN s2.sepsis3_sofa2_delta = true THEN 1 ELSE 0 END
       OR d.sepsis3_primary_delta_any IS DISTINCT FROM CASE
            WHEN COALESCE(s1.sepsis3_sofa1_delta, false)
              OR COALESCE(s2.sepsis3_sofa2_delta, false)
            THEN 1 ELSE 0
          END
       OR d.sepsis3_primary_policy IS DISTINCT FROM 'sofa1_delta_or_sofa2_delta';

    IF mismatch_n <> 0 THEN
        RAISE EXCEPTION 'sepsis3_definitions_current mismatches shadow delta tables: %', mismatch_n;
    END IF;
END $$;

\echo 'Validation: patient_outcomes SOFA-2 score matches shadow first-day total'

DO $$
DECLARE
    mismatch_n bigint;
BEGIN
    SELECT COUNT(*) INTO mismatch_n
    FROM patient_outcomes p
    JOIN first_day_sofa2 f USING (stay_id)
    WHERE p.sofa2_score IS DISTINCT FROM f.sofa2_total_lab48_rescue;

    IF mismatch_n <> 0 THEN
        RAISE EXCEPTION 'patient_outcomes.sofa2_score mismatches shadow first-day total: %', mismatch_n;
    END IF;
END $$;

\echo 'Validation: patient_outcomes sepsis flags match shadow sepsis definitions'

DO $$
DECLARE
    mismatch_n bigint;
BEGIN
    SELECT COUNT(*) INTO mismatch_n
    FROM patient_outcomes p
    JOIN sepsis3_definitions_current d USING (stay_id)
    WHERE p.sepsis3_sofa1_official_absolute IS DISTINCT FROM d.sepsis3_sofa1_official_absolute
       OR p.sepsis3_sofa1_delta IS DISTINCT FROM d.sepsis3_sofa1_delta
       OR p.sepsis3_sofa2_delta IS DISTINCT FROM d.sepsis3_sofa2_delta
       OR p.sepsis3_primary_delta_any IS DISTINCT FROM d.sepsis3_primary_delta_any
       OR p.sepsis3_primary_policy IS DISTINCT FROM d.sepsis3_primary_policy
       OR p.sepsis3_sofa1_baseline IS DISTINCT FROM d.sepsis3_sofa1_baseline
       OR p.sepsis3_sofa1_delta_value IS DISTINCT FROM d.sepsis3_sofa1_delta_value
       OR p.sepsis3_sofa2_baseline IS DISTINCT FROM d.sepsis3_sofa2_baseline
       OR p.sepsis3_sofa2_delta_value IS DISTINCT FROM d.sepsis3_sofa2_delta_value;

    IF mismatch_n <> 0 THEN
        RAISE EXCEPTION 'patient_outcomes sepsis fields mismatch sepsis3_definitions_current: %', mismatch_n;
    END IF;
END $$;

\echo 'Validation: governed survival source agreement'

DO $$
DECLARE
    mismatch_n bigint;
BEGIN
    SELECT COUNT(*) INTO mismatch_n
    FROM patient_outcomes p
    JOIN mimiciv_team.survival_outcomes so USING (stay_id)
    WHERE p.event_status IS DISTINCT FROM so.event_status
       OR p.survival_days IS DISTINCT FROM so.survival_days
       OR p.icu_death_within_28_days IS DISTINCT FROM so.os_28d_status
       OR p.icu_death_within_90_days IS DISTINCT FROM so.os_90d_status
       OR p.mortality_1yr IS DISTINCT FROM so.os_1yr_status
       OR p.survival_qa_any_flag IS DISTINCT FROM so.qa_any_flag;

    IF mismatch_n <> 0 THEN
        RAISE EXCEPTION 'patient_outcomes governed survival fields mismatch survival_outcomes: %', mismatch_n;
    END IF;
END $$;

\echo 'Validation: current-vs-shadow first-day SOFA-2 difference table'

DO $$
DECLARE
    shadow_schema text := current_setting('app.shadow_schema');
    diff_n bigint;
BEGIN
    EXECUTE format('DROP TABLE IF EXISTS %I.validation_current_vs_shadow_sofa2_first_day_diff', shadow_schema);

    EXECUTE format($sql$
        CREATE TABLE %I.validation_current_vs_shadow_sofa2_first_day_diff AS
        SELECT
            COALESCE(c.stay_id, f.stay_id) AS stay_id,
            c."SOFA_2" AS current_sofa2,
            f.sofa2_total_lab48_rescue AS shadow_sofa2,
            f.sofa2_total_lab48_rescue - c."SOFA_2" AS diff
        FROM mimiciv_derived.sofa2_first_day_current c
        FULL JOIN %I.first_day_sofa2 f USING (stay_id)
        WHERE c.stay_id IS NULL
           OR f.stay_id IS NULL
           OR c."SOFA_2" IS DISTINCT FROM f.sofa2_total_lab48_rescue
    $sql$, shadow_schema, shadow_schema);

    EXECUTE format(
        'SELECT COUNT(*) FROM %I.validation_current_vs_shadow_sofa2_first_day_diff',
        shadow_schema
    ) INTO diff_n;

    RAISE NOTICE 'current_vs_shadow_sofa2_first_day_diff_n=%', diff_n;
END $$;

\echo 'Shadow validation completed'
