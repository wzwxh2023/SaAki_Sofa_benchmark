-- Promote validated MIMIC-IV SOFA governance artifacts from shadow schema.
--
-- DANGER: this script changes current production interfaces in mimiciv_derived.
-- It must be reviewed before execution and requires an explicit psql variable:
--
--   psql ... \
--     -v confirm_promotion=I_HAVE_REVIEWED_AND_APPROVE_SOFA_GOV_20260619 \
--     -f sql/promote_sofa_gov_20260619_rebuild_v1.sql
--
-- Source shadow schema:
--   sofa_gov_20260619_rebuild_v1
--
-- Promotion policy:
--   - SOFA-1 remains official MIMIC-derived.
--   - SOFA-2 primary is lab48_rescue_kidney_uorate.
--   - SOFA-2 first-day total is SUM(per-organ first-day maxima).
--   - Survival endpoints in patient outputs use mimiciv_team.survival_outcomes.
--   - Legacy base tables are moved to mimiciv_derived_archive, not dropped.

\set ON_ERROR_STOP on

\if :{?confirm_promotion}
\else
  \echo 'confirm_promotion is required; refusing to promote current DB interfaces'
  DO $$ BEGIN RAISE EXCEPTION 'confirm_promotion is required'; END $$;
\endif

SELECT set_config('app.confirm_promotion', :'confirm_promotion', false);

DO $$
BEGIN
    IF current_setting('app.confirm_promotion', true)
       <> 'I_HAVE_REVIEWED_AND_APPROVE_SOFA_GOV_20260619' THEN
        RAISE EXCEPTION 'confirm_promotion value is not the required approval token';
    END IF;
END $$;

BEGIN;

DO $$
DECLARE
    required_object text;
BEGIN
    FOREACH required_object IN ARRAY ARRAY[
        'sofa_gov_20260619_rebuild_v1.sofa2_scores_hr_filtered',
        'sofa_gov_20260619_rebuild_v1.first_day_sofa2',
        'sofa_gov_20260619_rebuild_v1.sepsis3_sofa1_delta',
        'sofa_gov_20260619_rebuild_v1.sepsis3_sofa2_delta',
        'sofa_gov_20260619_rebuild_v1.sepsis3_definitions_current',
        'sofa_gov_20260619_rebuild_v1.patient_outcomes',
        'mimiciv_team.survival_outcomes',
        'mimiciv_derived.sofa_governance_manifest',
        'mimiciv_derived.sofa2_hourly_sensitivity_current',
        'mimiciv_derived.sofa2_first_day_sensitivity_current',
        'mimiciv_derived.sofa_first_day_sensitivity_current',
        'mimiciv_derived_archive.first_day_sofa1_official_strict24_legacy_pre_labwindow_20260616',
        'mimiciv_derived_archive.sofa1_hourly_official_strict24_legacy_pre_labwindow_20260616'
    ]
    LOOP
        IF to_regclass(required_object) IS NULL THEN
            RAISE EXCEPTION 'Missing required promotion source object: %', required_object;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM sofa_gov_20260619_rebuild_v1.validation_current_vs_shadow_sofa2_first_day_diff
    ) THEN
        RAISE EXCEPTION 'Shadow first-day SOFA-2 still differs from current view; review validation before promotion';
    END IF;

    IF to_regclass('mimiciv_derived_archive.patient_outcomes_pre_shadow_20260619') IS NOT NULL
       OR to_regclass('mimiciv_derived_archive.sepsis3_definitions_current_pre_shadow_20260619') IS NOT NULL
       OR to_regclass('mimiciv_derived_archive.sepsis3_sofa1_delta_pre_shadow_20260619') IS NOT NULL
       OR to_regclass('mimiciv_derived_archive.sepsis3_sofa2_delta_pre_shadow_20260619') IS NOT NULL THEN
        RAISE EXCEPTION 'One or more 20260619 archive tables already exist; aborting to avoid overwrite';
    END IF;

    IF to_regclass('mimiciv_derived.sofa_first_day_policy_v20260619_current') IS NOT NULL
       OR to_regclass('mimiciv_derived.sofa2_hourly_policy_v20260619_current') IS NOT NULL THEN
        RAISE EXCEPTION 'One or more 20260619 current SOFA policy artifact tables already exist; aborting to avoid overwrite';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS mimiciv_derived_archive;

DO $$
BEGIN
    IF to_regclass('mimiciv_derived_archive.patient_outcomes') IS NOT NULL THEN
        IF to_regclass('mimiciv_derived_archive.patient_outcomes_legacy_pre_shadow_promotion_20260619') IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot rename existing archive patient_outcomes: target legacy name already exists';
        END IF;
        ALTER TABLE mimiciv_derived_archive.patient_outcomes RENAME TO patient_outcomes_legacy_pre_shadow_promotion_20260619;
        COMMENT ON TABLE mimiciv_derived_archive.patient_outcomes_legacy_pre_shadow_promotion_20260619 IS
            'ARCHIVED LEGACY: pre-existing unversioned archive table renamed during 2026-06-19 SOFA governance promotion to avoid current-table archive name collision. Do not use as current.';
    END IF;

    IF to_regclass('mimiciv_derived_archive.sepsis3_definitions_current') IS NOT NULL THEN
        IF to_regclass('mimiciv_derived_archive.sepsis3_definitions_current_legacy_pre_shadow_promotion_20260619') IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot rename existing archive sepsis3_definitions_current: target legacy name already exists';
        END IF;
        ALTER TABLE mimiciv_derived_archive.sepsis3_definitions_current RENAME TO sepsis3_definitions_current_legacy_pre_shadow_promotion_20260619;
        COMMENT ON TABLE mimiciv_derived_archive.sepsis3_definitions_current_legacy_pre_shadow_promotion_20260619 IS
            'ARCHIVED LEGACY: pre-existing unversioned archive table renamed during 2026-06-19 SOFA governance promotion to avoid current-table archive name collision. Do not use as current.';
    END IF;

    IF to_regclass('mimiciv_derived_archive.sepsis3_sofa1_delta') IS NOT NULL THEN
        IF to_regclass('mimiciv_derived_archive.sepsis3_sofa1_delta_legacy_pre_shadow_promotion_20260619') IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot rename existing archive sepsis3_sofa1_delta: target legacy name already exists';
        END IF;
        ALTER TABLE mimiciv_derived_archive.sepsis3_sofa1_delta RENAME TO sepsis3_sofa1_delta_legacy_pre_shadow_promotion_20260619;
        COMMENT ON TABLE mimiciv_derived_archive.sepsis3_sofa1_delta_legacy_pre_shadow_promotion_20260619 IS
            'ARCHIVED LEGACY: pre-existing unversioned archive table renamed during 2026-06-19 SOFA governance promotion to avoid current-table archive name collision. Do not use as current.';
    END IF;

    IF to_regclass('mimiciv_derived_archive.sepsis3_sofa2_delta') IS NOT NULL THEN
        IF to_regclass('mimiciv_derived_archive.sepsis3_sofa2_delta_legacy_pre_shadow_promotion_20260619') IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot rename existing archive sepsis3_sofa2_delta: target legacy name already exists';
        END IF;
        ALTER TABLE mimiciv_derived_archive.sepsis3_sofa2_delta RENAME TO sepsis3_sofa2_delta_legacy_pre_shadow_promotion_20260619;
        COMMENT ON TABLE mimiciv_derived_archive.sepsis3_sofa2_delta_legacy_pre_shadow_promotion_20260619 IS
            'ARCHIVED LEGACY: pre-existing unversioned archive table renamed during 2026-06-19 SOFA governance promotion to avoid current-table archive name collision. Do not use as current.';
    END IF;
END $$;

ALTER TABLE mimiciv_derived.patient_outcomes SET SCHEMA mimiciv_derived_archive;
ALTER TABLE mimiciv_derived_archive.patient_outcomes RENAME TO patient_outcomes_pre_shadow_20260619;

ALTER TABLE mimiciv_derived.sepsis3_definitions_current SET SCHEMA mimiciv_derived_archive;
ALTER TABLE mimiciv_derived_archive.sepsis3_definitions_current RENAME TO sepsis3_definitions_current_pre_shadow_20260619;

ALTER TABLE mimiciv_derived.sepsis3_sofa1_delta SET SCHEMA mimiciv_derived_archive;
ALTER TABLE mimiciv_derived_archive.sepsis3_sofa1_delta RENAME TO sepsis3_sofa1_delta_pre_shadow_20260619;

ALTER TABLE mimiciv_derived.sepsis3_sofa2_delta SET SCHEMA mimiciv_derived_archive;
ALTER TABLE mimiciv_derived_archive.sepsis3_sofa2_delta RENAME TO sepsis3_sofa2_delta_pre_shadow_20260619;

COMMENT ON TABLE mimiciv_derived_archive.patient_outcomes_pre_shadow_20260619 IS
    'ARCHIVED 2026-06-19: pre-shadow patient_outcomes table. Do not use as current.';
COMMENT ON TABLE mimiciv_derived_archive.sepsis3_definitions_current_pre_shadow_20260619 IS
    'ARCHIVED 2026-06-19: pre-shadow sepsis definitions table. Do not use as current.';
COMMENT ON TABLE mimiciv_derived_archive.sepsis3_sofa1_delta_pre_shadow_20260619 IS
    'ARCHIVED 2026-06-19: pre-shadow SOFA-1 delta sepsis table. Do not use as current.';
COMMENT ON TABLE mimiciv_derived_archive.sepsis3_sofa2_delta_pre_shadow_20260619 IS
    'ARCHIVED 2026-06-19: pre-shadow SOFA-2 delta sepsis table. Do not use as current.';

CREATE TABLE mimiciv_derived.sepsis3_sofa1_delta AS
SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_sofa1_delta;

CREATE TABLE mimiciv_derived.sepsis3_sofa2_delta AS
SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_sofa2_delta;

CREATE TABLE mimiciv_derived.sepsis3_definitions_current AS
SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_definitions_current;

CREATE TABLE mimiciv_derived.patient_outcomes AS
SELECT * FROM sofa_gov_20260619_rebuild_v1.patient_outcomes;

CREATE TABLE mimiciv_derived.sofa_first_day_policy_v20260619_current AS
SELECT
    'mimiciv'::text AS source_database,
    'first_day'::text AS time_scope,
    'one_row_per_icu_stay'::text AS row_granularity,
    'sofa_gov_20260619_shadow_v1'::text AS sofa_governance_version,
    'official_mimic'::text AS sofa1_primary_policy,
    'lab48_rescue_kidney_uorate'::text AS sofa2_primary_policy,
    'official_mimic_derived'::text AS sofa1_source_kind,
    'local_recomputed_current_artifact'::text AS sofa2_source_kind,
    o.stay_id,
    o.subject_id,
    o.hadm_id,
    o.sofa AS "SOFA",
    s.sofa2_total_lab48_rescue AS "SOFA_2",
    o.sofa AS sofa_official_mimic,
    s.sofa2_total_lab48_rescue AS sofa_2_lab48_rescue,
    o.respiration AS sofa_respiration_official_mimic,
    o.coagulation AS sofa_coagulation_official_mimic,
    o.liver AS sofa_liver_official_mimic,
    o.cardiovascular AS sofa_cardiovascular_official_mimic,
    o.cns AS sofa_cns_official_mimic,
    o.renal AS sofa_renal_official_mimic,
    s.brain AS sofa2_brain_lab48_rescue,
    s.respiratory AS sofa2_respiratory_lab48_rescue,
    s.cardiovascular AS sofa2_cardiovascular_lab48_rescue,
    s.kidney AS sofa2_kidney_lab48_rescue,
    s.hemostasis_lab48_rescue AS sofa2_hemostasis_lab48_rescue,
    s.liver_lab48_rescue AS sofa2_liver_lab48_rescue,
    CASE WHEN s.platelet_lab48_rescue_used THEN 1 ELSE 0 END AS sofa2_platelet_lab48_rescue_used,
    CASE WHEN s.bilirubin_lab48_rescue_used THEN 1 ELSE 0 END AS sofa2_bilirubin_lab48_rescue_used
FROM mimiciv_derived_archive.first_day_sofa1_official_strict24_legacy_pre_labwindow_20260616 o
JOIN sofa_gov_20260619_rebuild_v1.first_day_sofa2 s USING (stay_id);

CREATE TABLE mimiciv_derived.sofa2_hourly_policy_v20260619_current AS
SELECT
    'mimiciv'::text AS source_database,
    'hourly'::text AS time_scope,
    'one_row_per_icu_stay_hour_observed'::text AS row_granularity,
    'sofa_gov_20260619_shadow_v1'::text AS sofa_governance_version,
    'not_applicable'::text AS sofa1_primary_policy,
    'lab48_rescue_kidney_uorate'::text AS sofa2_primary_policy,
    'not_applicable'::text AS sofa1_source_kind,
    'local_recomputed_current_artifact'::text AS sofa2_source_kind,
    stay_id,
    subject_id,
    hadm_id,
    hr,
    starttime,
    endtime,
    sofa2_total_lab48_rescue AS "SOFA_2",
    sofa2_total_lab48_rescue AS sofa_2_lab48_rescue_hourly,
    brain AS sofa2_brain_lab48_rescue_hourly,
    respiratory AS sofa2_respiratory_lab48_rescue_hourly,
    cardiovascular AS sofa2_cardiovascular_lab48_rescue_hourly,
    kidney AS sofa2_kidney_lab48_rescue_hourly,
    hemostasis_lab48_rescue AS sofa2_hemostasis_lab48_rescue_hourly,
    liver_lab48_rescue AS sofa2_liver_lab48_rescue_hourly
FROM sofa_gov_20260619_rebuild_v1.sofa2_scores_hr_filtered;

CREATE INDEX idx_sepsis3_sofa1_delta_current_stay ON mimiciv_derived.sepsis3_sofa1_delta(stay_id);
CREATE INDEX idx_sepsis3_sofa2_delta_current_stay ON mimiciv_derived.sepsis3_sofa2_delta(stay_id);
CREATE INDEX idx_sepsis3_definitions_current_stay ON mimiciv_derived.sepsis3_definitions_current(stay_id);
CREATE INDEX idx_sepsis3_definitions_current_subject ON mimiciv_derived.sepsis3_definitions_current(subject_id);
CREATE INDEX idx_sepsis3_definitions_current_primary ON mimiciv_derived.sepsis3_definitions_current(sepsis3_primary_delta_any);
CREATE INDEX idx_patient_outcomes_current_subject ON mimiciv_derived.patient_outcomes(subject_id);
CREATE INDEX idx_patient_outcomes_current_stay ON mimiciv_derived.patient_outcomes(stay_id);
CREATE INDEX idx_patient_outcomes_current_hadm ON mimiciv_derived.patient_outcomes(hadm_id);
CREATE INDEX idx_patient_outcomes_current_mortality ON mimiciv_derived.patient_outcomes(hospital_mortality);
CREATE INDEX idx_patient_outcomes_current_icu_mortality ON mimiciv_derived.patient_outcomes(icu_mortality);
CREATE INDEX idx_patient_outcomes_current_sepsis_primary ON mimiciv_derived.patient_outcomes(sepsis3_primary_delta_any);
CREATE INDEX idx_sofa_first_day_policy_v20260619_current_stay ON mimiciv_derived.sofa_first_day_policy_v20260619_current(stay_id);
CREATE INDEX idx_sofa2_hourly_policy_v20260619_current_stay_hr ON mimiciv_derived.sofa2_hourly_policy_v20260619_current(stay_id, hr);

COMMENT ON TABLE mimiciv_derived.sepsis3_sofa1_delta IS
    'CURRENT SOFA-1 delta sepsis table promoted from sofa_gov_20260619_rebuild_v1.';
COMMENT ON TABLE mimiciv_derived.sepsis3_sofa2_delta IS
    'CURRENT SOFA-2 delta sepsis table promoted from sofa_gov_20260619_rebuild_v1.';
COMMENT ON TABLE mimiciv_derived.sepsis3_definitions_current IS
    'CURRENT governed sepsis definition flags promoted from sofa_gov_20260619_rebuild_v1.';
COMMENT ON TABLE mimiciv_derived.patient_outcomes IS
    'CURRENT patient outcomes table promoted from sofa_gov_20260619_rebuild_v1; survival fields use mimiciv_team.survival_outcomes.';
COMMENT ON TABLE mimiciv_derived.sofa_first_day_policy_v20260619_current IS
    'CURRENT paired SOFA-1/SOFA-2 first-day policy artifact promoted from sofa_gov_20260619_rebuild_v1.';
COMMENT ON TABLE mimiciv_derived.sofa2_hourly_policy_v20260619_current IS
    'CURRENT SOFA-2 hourly policy artifact promoted from sofa_gov_20260619_rebuild_v1.';

CREATE OR REPLACE VIEW mimiciv_derived.sofa_first_day_current AS
SELECT * FROM mimiciv_derived.sofa_first_day_policy_v20260619_current;

CREATE OR REPLACE VIEW mimiciv_derived.sofa1_first_day_current AS
SELECT
    source_database,
    time_scope,
    row_granularity,
    sofa_governance_version,
    sofa1_primary_policy,
    'not_applicable'::text AS sofa2_primary_policy,
    sofa1_source_kind,
    'not_applicable'::text AS sofa2_source_kind,
    stay_id,
    subject_id,
    hadm_id,
    "SOFA",
    sofa_official_mimic,
    sofa_respiration_official_mimic,
    sofa_coagulation_official_mimic,
    sofa_liver_official_mimic,
    sofa_cardiovascular_official_mimic,
    sofa_cns_official_mimic,
    sofa_renal_official_mimic
FROM mimiciv_derived.sofa_first_day_current;

CREATE OR REPLACE VIEW mimiciv_derived.sofa2_first_day_current AS
SELECT
    source_database,
    time_scope,
    row_granularity,
    sofa_governance_version,
    'not_applicable'::text AS sofa1_primary_policy,
    sofa2_primary_policy,
    'not_applicable'::text AS sofa1_source_kind,
    sofa2_source_kind,
    stay_id,
    subject_id,
    hadm_id,
    "SOFA_2",
    sofa_2_lab48_rescue,
    sofa2_brain_lab48_rescue,
    sofa2_respiratory_lab48_rescue,
    sofa2_cardiovascular_lab48_rescue,
    sofa2_kidney_lab48_rescue,
    sofa2_hemostasis_lab48_rescue,
    sofa2_liver_lab48_rescue,
    sofa2_platelet_lab48_rescue_used,
    sofa2_bilirubin_lab48_rescue_used
FROM mimiciv_derived.sofa_first_day_current;

CREATE OR REPLACE VIEW mimiciv_derived.sofa2_hourly_current AS
SELECT * FROM mimiciv_derived.sofa2_hourly_policy_v20260619_current;

CREATE OR REPLACE VIEW mimiciv_derived.sofa1_hourly_current AS
SELECT
    'mimiciv'::text AS source_database,
    'hourly'::text AS time_scope,
    'one_row_per_icu_stay_hour_observed'::text AS row_granularity,
    'sofa_gov_20260619_shadow_v1'::text AS sofa_governance_version,
    'official_mimic_hourly'::text AS sofa1_primary_policy,
    'not_applicable'::text AS sofa2_primary_policy,
    'official_mimic_derived'::text AS sofa1_source_kind,
    'not_applicable'::text AS sofa2_source_kind,
    s.stay_id,
    ie.subject_id,
    ie.hadm_id,
    s.hr,
    s.starttime,
    s.endtime,
    s.sofa_24hours AS "SOFA",
    s.sofa_24hours AS sofa_official_mimic_hourly,
    s.respiration_24hours AS sofa_respiration_official_mimic_hourly,
    s.coagulation_24hours AS sofa_coagulation_official_mimic_hourly,
    s.liver_24hours AS sofa_liver_official_mimic_hourly,
    s.cardiovascular_24hours AS sofa_cardiovascular_official_mimic_hourly,
    s.cns_24hours AS sofa_cns_official_mimic_hourly,
    s.renal_24hours AS sofa_renal_official_mimic_hourly
FROM mimiciv_derived_archive.sofa1_hourly_official_strict24_legacy_pre_labwindow_20260616 s
JOIN mimiciv_icu.icustays ie USING (stay_id)
WHERE s.hr >= 0;

CREATE OR REPLACE VIEW mimiciv_derived.patient_outcomes_sofa_current AS
SELECT
    'mimiciv'::text AS source_database,
    'first_day'::text AS time_scope,
    'one_row_per_icu_stay'::text AS row_granularity,
    'sofa_gov_20260619_shadow_v1'::text AS sofa_governance_version,
    'official_mimic'::text AS sofa1_primary_policy,
    'lab48_rescue_kidney_uorate'::text AS sofa2_primary_policy,
    'official_mimic_derived'::text AS sofa1_source_kind,
    'local_recomputed_current_artifact'::text AS sofa2_source_kind,
    p.subject_id,
    p.hadm_id,
    p.stay_id,
    p.gender,
    p.anchor_age_exact,
    p.race,
    p.insurance,
    p.admission_type,
    p.admission_location,
    p.first_careunit,
    p.last_careunit,
    p.icu_intime,
    p.icu_outtime,
    p.icu_los,
    p.adm_admittime,
    p.adm_dischtime,
    p.adm_deathtime,
    p.patient_dod,
    p.hospital_los,
    p.discharge_location,
    p.hospital_mortality,
    p.icu_mortality,
    p.event_status,
    p.survival_days,
    p.mortality_1yr,
    p.pre_icu_hospital_days,
    p.icu_death_within_28_days,
    p.icu_death_within_90_days,
    p.death_location,
    p.sofa_score,
    p.sofa2_score,
    p.sepsis3_sofa1_official_absolute AS sepsis3_sofa_official_mimic,
    p.invasive_ventilation,
    p.tracheostomy,
    p.noninvasive_ventilation,
    p.hfnc_ventilation,
    p.oxygen_only,
    p.invasive_ventilation_hours,
    p.noninvasive_ventilation_hours,
    p.hfnc_hours,
    p.advanced_respiratory_support_hours,
    p.time_to_invasive_vent_hours,
    p.time_to_noninvasive_vent_hours,
    p.time_to_hfnc_hours,
    p.time_to_advanced_support_hours,
    p.vasoactive_hours,
    p.rrt_required,
    p.rrt_types,
    p.rrt_sessions,
    p.rrt_hours,
    p.crrt_sessions,
    p.cvvhdf_sessions,
    p.cvvhd_sessions,
    p.cvvh_sessions,
    p.ihd_sessions,
    p.peritoneal_sessions,
    p.scuf_sessions,
    p.icu_readmission,
    p.prior_icu_stays,
    p.icu_admission_number,
    so.death_source AS survival_death_source,
    so.qa_any_flag AS survival_qa_any_flag,
    so.os_28d_time,
    so.os_28d_status,
    so.os_90d_time,
    so.os_90d_status,
    so.os_180d_time,
    so.os_180d_status,
    so.os_1yr_time,
    so.os_1yr_status
FROM mimiciv_derived.patient_outcomes p
JOIN mimiciv_team.survival_outcomes so USING (stay_id);

UPDATE mimiciv_derived.sofa_governance_manifest
SET is_active = false
WHERE is_active = true;

DELETE FROM mimiciv_derived.sofa_governance_manifest
WHERE sofa_governance_version = 'sofa_gov_20260619_shadow_v1';

INSERT INTO mimiciv_derived.sofa_governance_manifest (
    sofa_governance_version,
    source_database,
    time_scope,
    row_granularity,
    interface_name,
    interface_role,
    sofa1_primary_policy,
    sofa2_primary_policy,
    sofa1_source_kind,
    sofa2_source_kind,
    current_view,
    sensitivity_current_view,
    artifact_table,
    archive_table,
    row_count,
    unique_key_count,
    is_active,
    installed_at,
    installed_by,
    notes
)
SELECT * FROM (
    SELECT
        'sofa_gov_20260619_shadow_v1'::text,
        'mimiciv'::text,
        'hourly'::text,
        'one_row_per_icu_stay_hour_observed'::text,
        'mimiciv_derived.sofa1_hourly_current'::text,
        'sofa1_hourly_current'::text,
        'official_mimic_hourly'::text,
        'not_applicable'::text,
        'official_mimic_derived'::text,
        'not_applicable'::text,
        'mimiciv_derived.sofa1_hourly_current'::text,
        NULL::text,
        'mimiciv_derived_archive.sofa1_hourly_official_strict24_legacy_pre_labwindow_20260616'::text,
        NULL::text,
        COUNT(*)::bigint,
        COUNT(DISTINCT stay_id)::bigint,
        true,
        now(),
        current_user::text,
        'SOFA-1 hourly current; official MIMIC-derived source with 2026-06-19 governance label.'::text
    FROM mimiciv_derived.sofa1_hourly_current

    UNION ALL
    SELECT
        'sofa_gov_20260619_shadow_v1'::text,
        'mimiciv'::text,
        'hourly'::text,
        'one_row_per_icu_stay_hour_observed'::text,
        'mimiciv_derived.sofa2_hourly_current'::text,
        'sofa2_hourly_current'::text,
        'not_applicable'::text,
        'lab48_rescue_kidney_uorate'::text,
        'not_applicable'::text,
        'local_recomputed_current_artifact'::text,
        'mimiciv_derived.sofa2_hourly_current'::text,
        'mimiciv_derived.sofa2_hourly_sensitivity_current'::text,
        'mimiciv_derived.sofa2_hourly_policy_v20260619_current'::text,
        NULL::text,
        COUNT(*)::bigint,
        COUNT(DISTINCT stay_id)::bigint,
        true,
        now(),
        current_user::text,
        'SOFA-2 hourly current promoted from validated shadow schema.'::text
    FROM mimiciv_derived.sofa2_hourly_policy_v20260619_current

    UNION ALL
    SELECT
        'sofa_gov_20260619_shadow_v1', 'mimiciv', 'first_day', 'one_row_per_icu_stay',
        'mimiciv_derived.sofa2_first_day_current', 'sofa2_first_day_current',
        'not_applicable', 'lab48_rescue_kidney_uorate', 'not_applicable', 'local_recomputed_current_artifact',
        'mimiciv_derived.sofa2_first_day_current', 'mimiciv_derived.sofa2_first_day_sensitivity_current',
        'mimiciv_derived.sofa_first_day_policy_v20260619_current', NULL,
        COUNT(*)::bigint, COUNT(DISTINCT stay_id)::bigint, true, now(), current_user::text,
        'SOFA-2 first-day current promoted from validated shadow schema.'
    FROM mimiciv_derived.sofa_first_day_policy_v20260619_current

    UNION ALL
    SELECT
        'sofa_gov_20260619_shadow_v1', 'mimiciv', 'first_day', 'one_row_per_icu_stay',
        'mimiciv_derived.sofa1_first_day_current', 'sofa1_first_day_current',
        'official_mimic', 'not_applicable', 'official_mimic_derived', 'not_applicable',
        'mimiciv_derived.sofa1_first_day_current', NULL,
        'mimiciv_derived_archive.first_day_sofa1_official_strict24_legacy_pre_labwindow_20260616', NULL,
        COUNT(*)::bigint, COUNT(DISTINCT stay_id)::bigint, true, now(), current_user::text,
        'SOFA-1 first-day current; official MIMIC-derived source with 2026-06-19 governance label.'
    FROM mimiciv_derived.sofa1_first_day_current

    UNION ALL
    SELECT
        'sofa_gov_20260619_shadow_v1', 'mimiciv', 'first_day', 'one_row_per_icu_stay',
        'mimiciv_derived.sofa_first_day_current', 'paired_first_day_current',
        'official_mimic', 'lab48_rescue_kidney_uorate', 'official_mimic_derived', 'local_recomputed_current_artifact',
        'mimiciv_derived.sofa_first_day_current', 'mimiciv_derived.sofa_first_day_sensitivity_current',
        'mimiciv_derived.sofa_first_day_policy_v20260619_current', NULL,
        COUNT(*)::bigint, COUNT(DISTINCT stay_id)::bigint, true, now(), current_user::text,
        'Paired SOFA-1/SOFA-2 first-day current; SOFA-1 official, SOFA-2 from validated shadow schema.'
    FROM mimiciv_derived.sofa_first_day_current

    UNION ALL
    SELECT
        'sofa_gov_20260619_shadow_v1', 'mimiciv', 'first_day', 'one_row_per_icu_stay',
        'mimiciv_derived.patient_outcomes_sofa_current', 'outcomes_current',
        'official_mimic', 'lab48_rescue_kidney_uorate', 'official_mimic_derived', 'local_recomputed_current_artifact',
        'mimiciv_derived.patient_outcomes_sofa_current', 'mimiciv_derived.sofa_first_day_sensitivity_current',
        'mimiciv_derived.patient_outcomes', NULL,
        COUNT(*)::bigint, COUNT(DISTINCT stay_id)::bigint, true, now(), current_user::text,
        'Comprehensive current outcomes interface; survival endpoints use mimiciv_team.survival_outcomes.'
    FROM mimiciv_derived.patient_outcomes_sofa_current

    UNION ALL
    SELECT
        'sofa_gov_20260619_shadow_v1', 'mimiciv', 'infection_window', 'one_row_per_icu_stay',
        'mimiciv_derived.sepsis3_definitions_current', 'sepsis_definitions_current',
        'official_mimic_delta_available', 'lab48_rescue_kidney_uorate_delta_available',
        'official_mimic_derived', 'local_recomputed_current_artifact',
        'mimiciv_derived.sepsis3_definitions_current', NULL,
        'mimiciv_derived.sepsis3_definitions_current', NULL,
        COUNT(*)::bigint, COUNT(DISTINCT stay_id)::bigint, true, now(), current_user::text,
        'Current sepsis definition flags: official SOFA-1 absolute, SOFA-1 delta, SOFA-2 delta, and selectable delta union.'
    FROM mimiciv_derived.sepsis3_definitions_current
) manifest_rows;

COMMENT ON VIEW mimiciv_derived.sofa_first_day_current IS
    'CURRENT MIMIC paired first-day SOFA view, governance sofa_gov_20260619_shadow_v1.';
COMMENT ON VIEW mimiciv_derived.sofa1_first_day_current IS
    'CURRENT MIMIC first-day SOFA-1 split view, governance sofa_gov_20260619_shadow_v1.';
COMMENT ON VIEW mimiciv_derived.sofa1_hourly_current IS
    'CURRENT MIMIC hourly SOFA-1 split view, governance sofa_gov_20260619_shadow_v1.';
COMMENT ON VIEW mimiciv_derived.sofa2_first_day_current IS
    'CURRENT MIMIC first-day SOFA-2 split view, governance sofa_gov_20260619_shadow_v1.';
COMMENT ON VIEW mimiciv_derived.sofa2_hourly_current IS
    'CURRENT MIMIC hourly SOFA-2 split view, governance sofa_gov_20260619_shadow_v1.';
COMMENT ON VIEW mimiciv_derived.patient_outcomes_sofa_current IS
    'CURRENT MIMIC comprehensive outcomes interface, governance sofa_gov_20260619_shadow_v1.';

COMMIT;

\echo 'Promotion completed. Run tests/validate_post_promotion_sofa_gov_20260619.sql immediately.'
