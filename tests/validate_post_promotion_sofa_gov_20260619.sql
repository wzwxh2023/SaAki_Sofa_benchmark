\set ON_ERROR_STOP on
-- Post-promotion gate for sofa_gov_20260619_shadow_v1.
-- Uses pg_temp helpers only; it does not write to mimiciv_derived.
CREATE OR REPLACE FUNCTION pg_temp.assert_zero(query text, label text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    n bigint;
BEGIN
    EXECUTE query INTO n;
    IF n <> 0 THEN
        RAISE EXCEPTION '% failed: % mismatches', label, n;
    END IF;
END $$;
DO $$
DECLARE
    required_object text;
BEGIN
    FOREACH required_object IN ARRAY ARRAY[
        'mimiciv_derived.sofa1_hourly_current',
        'mimiciv_derived.sofa2_hourly_current',
        'mimiciv_derived.sofa1_first_day_current',
        'mimiciv_derived.sofa2_first_day_current',
        'mimiciv_derived.sofa_first_day_current',
        'mimiciv_derived.sofa_first_day_policy_v20260619_current',
        'mimiciv_derived.sofa2_hourly_policy_v20260619_current',
        'mimiciv_derived.patient_outcomes',
        'mimiciv_derived.patient_outcomes_sofa_current',
        'mimiciv_derived.sepsis3_sofa1_delta',
        'mimiciv_derived.sepsis3_sofa2_delta',
        'mimiciv_derived.sepsis3_definitions_current',
        'mimiciv_derived_archive.patient_outcomes_pre_shadow_20260619',
        'mimiciv_derived_archive.sepsis3_definitions_current_pre_shadow_20260619',
        'mimiciv_derived_archive.sepsis3_sofa1_delta_pre_shadow_20260619',
        'mimiciv_derived_archive.sepsis3_sofa2_delta_pre_shadow_20260619',
        'mimiciv_derived_archive.first_day_sofa1_official_strict24_legacy_pre_labwindow_20260616',
        'mimiciv_derived_archive.sofa1_hourly_official_strict24_legacy_pre_labwindow_20260616',
        'sofa_gov_20260619_rebuild_v1.first_day_sofa2',
        'sofa_gov_20260619_rebuild_v1.sofa2_scores_hr_filtered',
        'sofa_gov_20260619_rebuild_v1.patient_outcomes',
        'sofa_gov_20260619_rebuild_v1.sepsis3_sofa1_delta',
        'sofa_gov_20260619_rebuild_v1.sepsis3_sofa2_delta',
        'sofa_gov_20260619_rebuild_v1.sepsis3_definitions_current',
        'mimiciv_team.survival_outcomes'
    ]
    LOOP
        IF to_regclass(required_object) IS NULL THEN
            RAISE EXCEPTION 'Missing required post-promotion object: %', required_object;
        END IF;
    END LOOP;
END $$;
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM (SELECT COUNT(*) n, COUNT(DISTINCT stay_id) s FROM mimiciv_derived.sofa1_hourly_current) c
    CROSS JOIN (SELECT COUNT(*) n, COUNT(DISTINCT stay_id) s FROM mimiciv_derived_archive.sofa1_hourly_official_strict24_legacy_pre_labwindow_20260616 WHERE hr >= 0) src
    WHERE c.n <> src.n OR c.s <> src.s
$q$, 'SOFA-1 hourly row/stay count');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sofa1_hourly_current
    WHERE "SOFA" IS DISTINCT FROM COALESCE(sofa_respiration_official_mimic_hourly,0)+COALESCE(sofa_coagulation_official_mimic_hourly,0)+COALESCE(sofa_liver_official_mimic_hourly,0)+COALESCE(sofa_cardiovascular_official_mimic_hourly,0)+COALESCE(sofa_cns_official_mimic_hourly,0)+COALESCE(sofa_renal_official_mimic_hourly,0)
$q$, 'SOFA-1 hourly total component sum');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM (SELECT COUNT(*) n, COUNT(DISTINCT stay_id) s FROM mimiciv_derived.sofa2_hourly_current) c
    CROSS JOIN (SELECT COUNT(*) n, COUNT(DISTINCT stay_id) s FROM sofa_gov_20260619_rebuild_v1.sofa2_scores_hr_filtered) src
    WHERE c.n <> src.n OR c.s <> src.s
$q$, 'SOFA-2 hourly row/stay count');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sofa2_hourly_current c
    FULL JOIN sofa_gov_20260619_rebuild_v1.sofa2_scores_hr_filtered s ON c.stay_id=s.stay_id AND c.hr=s.hr
    WHERE c.stay_id IS NULL OR s.stay_id IS NULL
       OR c.hadm_id IS DISTINCT FROM s.hadm_id OR c.subject_id IS DISTINCT FROM s.subject_id
       OR c.starttime IS DISTINCT FROM s.starttime OR c.endtime IS DISTINCT FROM s.endtime
       OR c."SOFA_2" IS DISTINCT FROM s.sofa2_total_lab48_rescue
       OR c.sofa2_brain_lab48_rescue_hourly IS DISTINCT FROM s.brain
       OR c.sofa2_respiratory_lab48_rescue_hourly IS DISTINCT FROM s.respiratory
       OR c.sofa2_cardiovascular_lab48_rescue_hourly IS DISTINCT FROM s.cardiovascular
       OR c.sofa2_kidney_lab48_rescue_hourly IS DISTINCT FROM s.kidney
       OR c.sofa2_hemostasis_lab48_rescue_hourly IS DISTINCT FROM s.hemostasis_lab48_rescue
       OR c.sofa2_liver_lab48_rescue_hourly IS DISTINCT FROM s.liver_lab48_rescue
$q$, 'SOFA-2 hourly current vs shadow');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sofa2_hourly_current
    WHERE "SOFA_2" IS DISTINCT FROM COALESCE(sofa2_brain_lab48_rescue_hourly,0)+COALESCE(sofa2_respiratory_lab48_rescue_hourly,0)+COALESCE(sofa2_cardiovascular_lab48_rescue_hourly,0)+COALESCE(sofa2_kidney_lab48_rescue_hourly,0)+COALESCE(sofa2_hemostasis_lab48_rescue_hourly,0)+COALESCE(sofa2_liver_lab48_rescue_hourly,0)
$q$, 'SOFA-2 hourly total component sum');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM (SELECT COUNT(*) n, COUNT(DISTINCT stay_id) s FROM mimiciv_derived.sofa1_first_day_current) c
    WHERE c.n <> 94458 OR c.s <> 94458
$q$, 'SOFA-1 first-day MIMIC-IV anchor count');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM (SELECT COUNT(*) n, COUNT(DISTINCT stay_id) s FROM mimiciv_derived.sofa_first_day_current) c
    WHERE c.n <> 94458 OR c.s <> 94458
$q$, 'paired SOFA first-day MIMIC-IV anchor count');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sofa1_first_day_current
    WHERE "SOFA" IS DISTINCT FROM COALESCE(sofa_respiration_official_mimic,0)+COALESCE(sofa_coagulation_official_mimic,0)+COALESCE(sofa_liver_official_mimic,0)+COALESCE(sofa_cardiovascular_official_mimic,0)+COALESCE(sofa_cns_official_mimic,0)+COALESCE(sofa_renal_official_mimic,0)
$q$, 'SOFA-1 first-day total component sum');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sofa2_first_day_current c
    FULL JOIN sofa_gov_20260619_rebuild_v1.first_day_sofa2 s USING (stay_id)
    WHERE c.stay_id IS NULL OR s.stay_id IS NULL
       OR c.hadm_id IS DISTINCT FROM s.hadm_id OR c.subject_id IS DISTINCT FROM s.subject_id
       OR c."SOFA_2" IS DISTINCT FROM s.sofa2_total_lab48_rescue
       OR c.sofa2_brain_lab48_rescue IS DISTINCT FROM s.brain
       OR c.sofa2_respiratory_lab48_rescue IS DISTINCT FROM s.respiratory
       OR c.sofa2_cardiovascular_lab48_rescue IS DISTINCT FROM s.cardiovascular
       OR c.sofa2_kidney_lab48_rescue IS DISTINCT FROM s.kidney
       OR c.sofa2_hemostasis_lab48_rescue IS DISTINCT FROM s.hemostasis_lab48_rescue
       OR c.sofa2_liver_lab48_rescue IS DISTINCT FROM s.liver_lab48_rescue
       OR c.sofa2_platelet_lab48_rescue_used IS DISTINCT FROM CASE WHEN s.platelet_lab48_rescue_used THEN 1 ELSE 0 END
       OR c.sofa2_bilirubin_lab48_rescue_used IS DISTINCT FROM CASE WHEN s.bilirubin_lab48_rescue_used THEN 1 ELSE 0 END
$q$, 'SOFA-2 first-day current vs shadow');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sofa2_first_day_current
    WHERE "SOFA_2" IS DISTINCT FROM COALESCE(sofa2_brain_lab48_rescue,0)+COALESCE(sofa2_respiratory_lab48_rescue,0)+COALESCE(sofa2_cardiovascular_lab48_rescue,0)+COALESCE(sofa2_kidney_lab48_rescue,0)+COALESCE(sofa2_hemostasis_lab48_rescue,0)+COALESCE(sofa2_liver_lab48_rescue,0)
$q$, 'SOFA-2 first-day total component sum');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM mimiciv_derived.sepsis3_sofa1_delta EXCEPT SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_sofa1_delta) d $q$, 'SOFA-1 delta sepsis current minus shadow');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_sofa1_delta EXCEPT SELECT * FROM mimiciv_derived.sepsis3_sofa1_delta) d $q$, 'SOFA-1 delta sepsis shadow minus current');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM mimiciv_derived.sepsis3_sofa2_delta EXCEPT SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_sofa2_delta) d $q$, 'SOFA-2 delta sepsis current minus shadow');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_sofa2_delta EXCEPT SELECT * FROM mimiciv_derived.sepsis3_sofa2_delta) d $q$, 'SOFA-2 delta sepsis shadow minus current');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM mimiciv_derived.sepsis3_definitions_current EXCEPT SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_definitions_current) d $q$, 'sepsis definitions current minus shadow');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM sofa_gov_20260619_rebuild_v1.sepsis3_definitions_current EXCEPT SELECT * FROM mimiciv_derived.sepsis3_definitions_current) d $q$, 'sepsis definitions shadow minus current');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sepsis3_definitions_current
    WHERE sepsis3_primary_delta_any IS DISTINCT FROM CASE WHEN sepsis3_sofa1_delta=1 OR sepsis3_sofa2_delta=1 THEN 1 ELSE 0 END
$q$, 'sepsis primary delta union');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM mimiciv_derived.patient_outcomes EXCEPT SELECT * FROM sofa_gov_20260619_rebuild_v1.patient_outcomes) d $q$, 'patient_outcomes current minus shadow');
SELECT pg_temp.assert_zero($q$ SELECT COUNT(*) FROM (SELECT * FROM sofa_gov_20260619_rebuild_v1.patient_outcomes EXCEPT SELECT * FROM mimiciv_derived.patient_outcomes) d $q$, 'patient_outcomes shadow minus current');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM (SELECT COUNT(*) n, COUNT(DISTINCT stay_id) s FROM mimiciv_derived.patient_outcomes) c
    WHERE c.n <> 94458 OR c.s <> 94458
$q$, 'patient_outcomes MIMIC-IV anchor count');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.patient_outcomes p
    JOIN mimiciv_derived.sofa1_first_day_current s1 USING (stay_id)
    JOIN mimiciv_derived.sofa2_first_day_current s2 USING (stay_id)
    JOIN mimiciv_team.survival_outcomes so USING (stay_id)
    JOIN mimiciv_derived.sepsis3_definitions_current sd USING (stay_id)
    WHERE p.sofa_score IS DISTINCT FROM s1."SOFA" OR p.sofa2_score IS DISTINCT FROM s2."SOFA_2"
       OR p.event_status IS DISTINCT FROM so.event_status OR p.survival_days IS DISTINCT FROM so.survival_days
       OR p.icu_death_within_28_days IS DISTINCT FROM so.os_28d_status
       OR p.icu_death_within_90_days IS DISTINCT FROM so.os_90d_status
       OR p.mortality_1yr IS DISTINCT FROM so.os_1yr_status
       OR p.sepsis3_sofa1_official_absolute IS DISTINCT FROM sd.sepsis3_sofa1_official_absolute
       OR p.sepsis3_sofa1_delta IS DISTINCT FROM sd.sepsis3_sofa1_delta
       OR p.sepsis3_sofa2_delta IS DISTINCT FROM sd.sepsis3_sofa2_delta
       OR p.sepsis3_primary_delta_any IS DISTINCT FROM sd.sepsis3_primary_delta_any
       OR p.sepsis3_primary_policy IS DISTINCT FROM sd.sepsis3_primary_policy
$q$, 'patient_outcomes links to current SOFA/sepsis/survival sources');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM (VALUES
        ('mimiciv_derived.sofa1_hourly_current'),('mimiciv_derived.sofa2_hourly_current'),
        ('mimiciv_derived.sofa1_first_day_current'),('mimiciv_derived.sofa2_first_day_current'),
        ('mimiciv_derived.sofa_first_day_current'),('mimiciv_derived.patient_outcomes_sofa_current'),
        ('mimiciv_derived.sepsis3_definitions_current')
    ) AS required(interface_name)
    LEFT JOIN mimiciv_derived.sofa_governance_manifest m ON m.interface_name=required.interface_name
      AND m.sofa_governance_version='sofa_gov_20260619_shadow_v1' AND m.is_active=true
    WHERE m.interface_name IS NULL
$q$, 'active governance manifest coverage');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(DISTINCT dependent_view.relname)
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid=d.objid
    JOIN pg_class dependent_view ON dependent_view.oid=r.ev_class
    JOIN pg_namespace dependent_ns ON dependent_ns.oid=dependent_view.relnamespace
    JOIN pg_class source_table ON source_table.oid=d.refobjid
    JOIN pg_namespace source_ns ON source_ns.oid=source_table.relnamespace
    WHERE dependent_ns.nspname='mimiciv_derived'
      AND dependent_view.relname IN ('sofa_first_day_current','sofa1_first_day_current','sofa2_first_day_current','sofa1_hourly_current','sofa2_hourly_current','patient_outcomes_sofa_current')
      AND source_ns.nspname='sofa_gov_20260619_rebuild_v1'
$q$, 'current views must not depend on shadow schema');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM mimiciv_derived.sofa_governance_manifest
    WHERE is_active=true AND interface_name LIKE 'mimiciv_derived.%' AND sofa_governance_version <> 'sofa_gov_20260619_shadow_v1'
$q$, 'inactive old MIMIC governance manifest rows');
SELECT pg_temp.assert_zero($q$
    SELECT COUNT(*) FROM (VALUES
        ('mimiciv_derived_archive.patient_outcomes_pre_shadow_20260619'::regclass),
        ('mimiciv_derived_archive.sepsis3_definitions_current_pre_shadow_20260619'::regclass),
        ('mimiciv_derived_archive.sepsis3_sofa1_delta_pre_shadow_20260619'::regclass),
        ('mimiciv_derived_archive.sepsis3_sofa2_delta_pre_shadow_20260619'::regclass)
    ) AS archived(object_id)
    WHERE COALESCE(obj_description(archived.object_id), '') NOT LIKE 'ARCHIVED 2026-06-19:%'
$q$, 'archive comments');
SELECT 'Post-promotion validation completed' AS status;
