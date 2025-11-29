-- =================================================================
-- 步骤 1: 环境配置与清理
-- =================================================================
SET work_mem = '2047MB';
SET maintenance_work_mem = '2047MB';
SET max_parallel_workers = 24;
SET max_parallel_workers_per_gather = 12;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
SET enable_parallel_hash = on;
SET jit = off;

-- 清理可能存在的旧表 (全部使用 UNLOGGED 表以提升写入速度)
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_sedation CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_vent CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_sf CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_mech CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_bilirubin CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_kidney_labs CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_rrt CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_urine CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_platelets CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_hourly_raw CASCADE;
-- 缺少以下表的清理：
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_delirium CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_brain CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_resp_support CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_oxygen CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_coag CASCADE;
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_liver CASCADE;