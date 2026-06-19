-- Preflight checks for governed MIMIC-IV SOFA-2 rebuild.
-- This script is read-only and must pass before any shadow rebuild runs.

\echo 'Preflight: required governed source objects'

DO $$
BEGIN
    IF to_regclass('mimiciv_derived.sofa1_hourly_current') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.sofa1_hourly_current';
    END IF;

    IF to_regclass('mimiciv_derived.sofa_first_day_current') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.sofa_first_day_current';
    END IF;

    IF to_regclass('mimiciv_derived.urine_output_rate') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.urine_output_rate';
    END IF;

    IF to_regclass('mimiciv_derived.suspicion_of_infection') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.suspicion_of_infection';
    END IF;

    IF to_regclass('mimiciv_derived.sepsis3') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.sepsis3';
    END IF;

    IF to_regclass('mimiciv_derived.ventilation') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.ventilation';
    END IF;

    IF to_regclass('mimiciv_derived.vitalsign') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.vitalsign';
    END IF;

    IF to_regclass('mimiciv_derived.vasoactive_agent') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.vasoactive_agent';
    END IF;

    IF to_regclass('mimiciv_derived.rrt') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.rrt';
    END IF;

    IF to_regclass('mimiciv_derived.gcs') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.gcs';
    END IF;

    IF to_regclass('mimiciv_derived.bg') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.bg';
    END IF;

    IF to_regclass('mimiciv_derived.chemistry') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.chemistry';
    END IF;

    IF to_regclass('mimiciv_derived.complete_blood_count') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.complete_blood_count';
    END IF;

    IF to_regclass('mimiciv_derived.enzyme') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.enzyme';
    END IF;

    IF to_regclass('mimiciv_team.survival_outcomes') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_team.survival_outcomes';
    END IF;

    IF to_regclass('mimiciv_derived.sofa_governance_manifest') IS NULL THEN
        RAISE EXCEPTION 'Missing required object: mimiciv_derived.sofa_governance_manifest';
    END IF;
END $$;

\echo 'Preflight: required row counts'

DO $$
DECLARE
    row_n bigint;
    stay_n bigint;
BEGIN
    SELECT COUNT(*) INTO row_n
    FROM mimiciv_derived.sofa1_hourly_current;
    IF row_n < 1000000 THEN
        RAISE EXCEPTION 'mimiciv_derived.sofa1_hourly_current row count %, expected at least 1000000', row_n;
    END IF;

    SELECT COUNT(DISTINCT stay_id) INTO stay_n
    FROM mimiciv_derived.sofa_first_day_current;
    IF stay_n <> 94458 THEN
        RAISE EXCEPTION 'mimiciv_derived.sofa_first_day_current stay count %, expected 94458', stay_n;
    END IF;

    SELECT COUNT(*) INTO row_n
    FROM mimiciv_derived.urine_output_rate;
    IF row_n = 0 THEN
        RAISE EXCEPTION 'mimiciv_derived.urine_output_rate is empty';
    END IF;

    SELECT COUNT(DISTINCT stay_id) INTO stay_n
    FROM mimiciv_team.survival_outcomes;
    IF stay_n <> 94458 THEN
        RAISE EXCEPTION 'mimiciv_team.survival_outcomes stay count %, expected 94458', stay_n;
    END IF;

    SELECT COUNT(*) INTO row_n
    FROM mimiciv_derived.sofa_governance_manifest
    WHERE is_active
      AND sofa2_primary_policy = 'lab48_rescue_kidney_uorate';
    IF row_n = 0 THEN
        RAISE EXCEPTION 'No active SOFA-2 policy lab48_rescue_kidney_uorate found in governance manifest';
    END IF;
END $$;

\echo 'Preflight passed'
