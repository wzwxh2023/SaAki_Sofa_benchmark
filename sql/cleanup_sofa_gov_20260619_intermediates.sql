\set ON_ERROR_STOP on

-- Cleanup reproducible SOFA-2 intermediate artifacts after the governed
-- 2026-06-19 MIMIC-IV SOFA promotion.
--
-- This script is intentionally destructive and must not be executed without
-- explicit user approval. It keeps current interfaces and shadow audit outputs.
--
-- Required run form:
-- psql -h 172.19.160.1 -U postgres -d mimiciv_31 -X \
--   -v ON_ERROR_STOP=1 \
--   -v confirm_cleanup=I_APPROVE_SOFA_GOV_20260619_INTERMEDIATE_CLEANUP \
--   -f sql/cleanup_sofa_gov_20260619_intermediates.sql

\if :{?confirm_cleanup}
\else
  \echo 'Missing required variable: confirm_cleanup'
  \quit 1
\endif

SELECT set_config('app.confirm_cleanup', :'confirm_cleanup', false);

DO $$
BEGIN
    IF current_setting('app.confirm_cleanup', true)
       <> 'I_APPROVE_SOFA_GOV_20260619_INTERMEDIATE_CLEANUP' THEN
        RAISE EXCEPTION 'confirm_cleanup value is not the required approval token';
    END IF;
END $$;

BEGIN;

CREATE TEMP TABLE cleanup_keep_shadow(relname text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO cleanup_keep_shadow(relname) VALUES
    ('first_day_sofa2'),
    ('sofa2_scores_hr_filtered'),
    ('patient_outcomes'),
    ('sepsis3_definitions_current'),
    ('sepsis3_sofa1_delta'),
    ('sepsis3_sofa2_delta'),
    ('validation_current_vs_shadow_sofa2_first_day_diff');

CREATE TEMP TABLE cleanup_drop_shadow(relname text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO cleanup_drop_shadow(relname) VALUES
    ('icustay_hourly_basedon_icuintime'),
    ('sofa2_hourly_raw'),
    ('sofa2_scores'),
    ('sofa2_stage1_brain'),
    ('sofa2_stage1_coag'),
    ('sofa2_stage1_delirium'),
    ('sofa2_stage1_kidney_labs'),
    ('sofa2_stage1_liver'),
    ('sofa2_stage1_mech'),
    ('sofa2_stage1_oxygen'),
    ('sofa2_stage1_resp_support'),
    ('sofa2_stage1_rrt'),
    ('sofa2_stage1_sedation'),
    ('sofa2_stage1_urine');

CREATE TEMP TABLE cleanup_drop_main(relname text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO cleanup_drop_main(relname) VALUES
    ('sofa2_stage1_brain'),
    ('sofa2_stage1_coag'),
    ('sofa2_stage1_delirium'),
    ('sofa2_stage1_kidney_labs'),
    ('sofa2_stage1_liver'),
    ('sofa2_stage1_mech'),
    ('sofa2_stage1_oxygen'),
    ('sofa2_stage1_resp_support'),
    ('sofa2_stage1_rrt'),
    ('sofa2_stage1_sedation'),
    ('sofa2_stage1_urine');

DO $$
DECLARE
    n bigint;
BEGIN
    IF to_regnamespace('sofa_gov_20260619_rebuild_v1') IS NULL THEN
        RAISE EXCEPTION 'Missing shadow schema: sofa_gov_20260619_rebuild_v1';
    END IF;

    SELECT COUNT(*) INTO n
    FROM cleanup_drop_main d
    WHERE to_regclass('mimiciv_derived.' || d.relname) IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION 'Some expected mimiciv_derived stage tables are missing; aborting cleanup';
    END IF;

    SELECT COUNT(*) INTO n
    FROM cleanup_keep_shadow k
    WHERE to_regclass('sofa_gov_20260619_rebuild_v1.' || k.relname) IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION 'Some required shadow audit tables are missing; aborting cleanup';
    END IF;

    SELECT COUNT(*) INTO n
    FROM cleanup_drop_shadow d
    WHERE to_regclass('sofa_gov_20260619_rebuild_v1.' || d.relname) IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION 'Some expected shadow intermediate tables are missing; aborting cleanup';
    END IF;

    SELECT COUNT(*) INTO n
    FROM pg_depend dep
    JOIN pg_rewrite rw ON rw.oid = dep.objid
    JOIN pg_class dependent_view ON dependent_view.oid = rw.ev_class
    JOIN pg_namespace dependent_ns ON dependent_ns.oid = dependent_view.relnamespace
    JOIN pg_class source_table ON source_table.oid = dep.refobjid
    JOIN pg_namespace source_ns ON source_ns.oid = source_table.relnamespace
    WHERE dependent_ns.nspname = 'mimiciv_derived'
      AND (
          source_ns.nspname = 'sofa_gov_20260619_rebuild_v1'
          OR (source_ns.nspname = 'mimiciv_derived' AND source_table.relname IN (SELECT relname FROM cleanup_drop_main))
      );
    IF n <> 0 THEN
        RAISE EXCEPTION 'Current mimiciv_derived views still depend on cleanup candidates; aborting cleanup';
    END IF;

    SELECT COUNT(*) INTO n
    FROM mimiciv_derived.sofa_governance_manifest
    WHERE is_active = true
      AND artifact_table LIKE 'sofa_gov_20260619_rebuild_v1.%';
    IF n <> 0 THEN
        RAISE EXCEPTION 'Active governance manifest points directly to shadow schema; aborting cleanup';
    END IF;

    SELECT COUNT(*) INTO n
    FROM (VALUES
        ('mimiciv_derived.patient_outcomes'::regclass),
        ('mimiciv_derived.sepsis3_definitions_current'::regclass),
        ('mimiciv_derived.sofa_first_day_policy_v20260619_current'::regclass),
        ('mimiciv_derived.sofa2_hourly_policy_v20260619_current'::regclass)
    ) AS required(object_id)
    WHERE required.object_id IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION 'Missing required promoted current artifact; aborting cleanup';
    END IF;
END $$;

DROP TABLE mimiciv_derived.sofa2_stage1_brain;
DROP TABLE mimiciv_derived.sofa2_stage1_coag;
DROP TABLE mimiciv_derived.sofa2_stage1_delirium;
DROP TABLE mimiciv_derived.sofa2_stage1_kidney_labs;
DROP TABLE mimiciv_derived.sofa2_stage1_liver;
DROP TABLE mimiciv_derived.sofa2_stage1_mech;
DROP TABLE mimiciv_derived.sofa2_stage1_oxygen;
DROP TABLE mimiciv_derived.sofa2_stage1_resp_support;
DROP TABLE mimiciv_derived.sofa2_stage1_rrt;
DROP TABLE mimiciv_derived.sofa2_stage1_sedation;
DROP TABLE mimiciv_derived.sofa2_stage1_urine;

DROP TABLE sofa_gov_20260619_rebuild_v1.icustay_hourly_basedon_icuintime;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_hourly_raw;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_scores;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_brain;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_coag;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_delirium;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_kidney_labs;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_liver;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_mech;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_oxygen;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_resp_support;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_rrt;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_sedation;
DROP TABLE sofa_gov_20260619_rebuild_v1.sofa2_stage1_urine;

COMMENT ON SCHEMA sofa_gov_20260619_rebuild_v1 IS
    'SOFA governance audit snapshot retained after 2026-06-19 promotion. Reproducible stage/raw intermediates removed after validation; this schema is not the current downstream source.';

COMMENT ON TABLE sofa_gov_20260619_rebuild_v1.first_day_sofa2 IS
    'Retained shadow audit output for 2026-06-19 SOFA promotion; not the current downstream source.';
COMMENT ON TABLE sofa_gov_20260619_rebuild_v1.sofa2_scores_hr_filtered IS
    'Retained shadow audit output for 2026-06-19 SOFA promotion; not the current downstream source.';
COMMENT ON TABLE sofa_gov_20260619_rebuild_v1.patient_outcomes IS
    'Retained shadow audit output for 2026-06-19 SOFA promotion; not the current downstream source.';
COMMENT ON TABLE sofa_gov_20260619_rebuild_v1.sepsis3_definitions_current IS
    'Retained shadow audit output for 2026-06-19 SOFA promotion; not the current downstream source.';
COMMENT ON TABLE sofa_gov_20260619_rebuild_v1.sepsis3_sofa1_delta IS
    'Retained shadow audit output for 2026-06-19 SOFA promotion; not the current downstream source.';
COMMENT ON TABLE sofa_gov_20260619_rebuild_v1.sepsis3_sofa2_delta IS
    'Retained shadow audit output for 2026-06-19 SOFA promotion; not the current downstream source.';

COMMIT;

SELECT 'SOFA 2026-06-19 intermediate cleanup completed' AS status;
