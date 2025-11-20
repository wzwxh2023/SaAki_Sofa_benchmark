-- =================================================================
-- SOFA-2 评分系统优化版本
-- 参考SOFA1的简洁结构，实现SOFA2最新标准
-- 性能优化：使用临时表突破CTE瓶颈
--
-- ⚠️ 重要执行说明：
-- 此脚本分为两段，必须按顺序执行：
-- 1. 首先执行临时表创建（第9-89行）
-- 2. 然后执行主查询（第91行至结尾）
--
-- 支持多语句执行的环境：DBeaver, pgAdmin, Python+psycopg2
-- 单语句环境：请分两次执行
-- =================================================================

-- =================================================================
-- 第一阶段：临时表管理与性能监控
-- =================================================================

-- 临时表管理：统一清理策略（防止冲突和资源泄漏）
DO $$
DECLARE
    cleanup_start TIMESTAMP := clock_timestamp();
BEGIN
    RAISE NOTICE '=== 开始临时表清理: % ===', cleanup_start;

    -- 清理所有可能残留的临时表
    DROP TABLE IF EXISTS temp_sedation_hourly CASCADE;
    DROP TABLE IF EXISTS temp_vent_periods CASCADE;
    DROP TABLE IF EXISTS temp_sf_ratios CASCADE;
    DROP TABLE IF EXISTS temp_mech_support CASCADE;

    RAISE NOTICE '✓ 临时表清理完成，耗时: %',
                 EXTRACT(EPOCH FROM (clock_timestamp() - cleanup_start)) || ' 秒';
END $$;

-- 第一阶段：创建临时表优化关键CTE性能瓶颈
DROP TABLE IF EXISTS temp_sedation_hourly CASCADE;
CREATE TEMP TABLE temp_sedation_hourly AS
WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
),
-- 镇静药物小写名称列表（反脆弱性设计：自动适应大小写变化）
sedation_drugs AS (
    SELECT UNNEST(ARRAY[
        'propofol', 'dexmedetomidine', 'midazolam', 'lorazepam',
        'diazepam', 'ketamine', 'clonidine', 'etomidate'
    ]) AS drug_name
),
-- 预过滤镇静药物记录（性能优化：使用CTE避免重复硬编码）
sedation_prescriptions_filtered AS (
    SELECT
        ie.stay_id,
        pr.starttime,
        pr.stoptime,
        1 AS is_sedation_drug
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE EXISTS (SELECT 1 FROM sedation_drugs sd WHERE LOWER(pr.drug) = sd.drug_name)
      AND pr.starttime IS NOT NULL
      AND pr.route IN ('IV DRIP', 'IV', 'Intravenous', 'IVPCA', 'SC', 'IM')
),
-- 优化的时间边界处理（简化逻辑）
sedation_infusion_periods AS (
    SELECT
        stay_id,
        starttime,
        CASE
            WHEN stoptime IS NOT NULL
                 AND stoptime > starttime
                 AND EXTRACT(EPOCH FROM (stoptime - starttime)) BETWEEN 3600 AND 604800
            THEN stoptime
            WHEN stoptime IS NOT NULL
                 AND stoptime > starttime
                 AND EXTRACT(EPOCH FROM (stoptime - starttime)) < 3600
            THEN starttime + INTERVAL '4 hours'
            WHEN stoptime IS NOT NULL
                 AND stoptime > starttime
                 AND EXTRACT(EPOCH FROM (stoptime - starttime)) > 604800
            THEN starttime + INTERVAL '7 days'
            WHEN stoptime IS NULL THEN starttime + INTERVAL '24 hours'
            ELSE stoptime
        END AS stoptime,
        is_sedation_drug
    FROM sedation_prescriptions_filtered
)
-- 预计算每小时的镇静状态（批量计算）
SELECT
    co.stay_id,
    co.hr,
    co.starttime,
    co.endtime,
    MAX(CASE
        WHEN sp.starttime <= co.endtime
             AND sp.stoptime > co.starttime
             AND sp.is_sedation_drug = 1
        THEN 1 ELSE 0
    END) AS has_sedation_infusion
FROM co
LEFT JOIN sedation_infusion_periods sp
    ON co.stay_id = sp.stay_id
    AND sp.starttime <= co.endtime
    AND sp.stoptime > co.starttime
GROUP BY co.stay_id, co.hr, co.starttime, co.endtime;

-- 为临时表创建索引，大幅提升后续JOIN性能
CREATE INDEX idx_temp_sedation_hourly_stay_hr ON temp_sedation_hourly (stay_id, hr);
CREATE INDEX idx_temp_sedation_hourly_time ON temp_sedation_hourly (stay_id, starttime, endtime);

-- 分析临时表以更新统计信息
ANALYZE temp_sedation_hourly;

-- 性能监控：temp_sedation_hourly 统计
DO $$
DECLARE
    record_count BIGINT;
    table_start TIMESTAMP := clock_timestamp();
BEGIN
    SELECT COUNT(*) INTO record_count FROM temp_sedation_hourly;
    RAISE NOTICE '✓ temp_sedation_hourly 创建完成: % 条记录，耗时统计完成', record_count;
END $$;

-- =================================================================
-- 第二阶段：主查询（使用临时表进行性能优化）
-- =================================================================

-- 性能监控：主查询开始
DO $$
DECLARE
    main_query_start TIMESTAMP := clock_timestamp();
BEGIN
    RAISE NOTICE '=== 开始主查询执行: % ===', main_query_start;
END $$;

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie
        ON ih.stay_id = ie.stay_id
),

-- =================================================================
-- 预处理步骤 (Staging CTEs) - 已优化：关键CTE移至临时表
-- =================================================================

-- 谵妄药物小写名称列表（反脆弱性设计：自动适应大小写变化）
delirium_drugs AS (
    SELECT UNNEST(ARRAY[
        'haloperidol', 'quetiapine', 'quetiapine fumarate', 'olanzapine',
        'olanzapine (disintegrating tablet)', 'risperidone',
        'risperidone (disintegrating tablet)', 'ziprasidone', 'ziprasidone hydrochloride',
        'clozapine', 'aripiprazole'
        -- 使用小写，自动处理所有大小写变体和剂型
    ]) AS drug_name
),

-- 步骤1: 预过滤谵妄药物记录（使用CTE避免重复硬编码）
delirium_prescriptions_filtered AS (
    SELECT
        ie.stay_id,
        pr.starttime,
        pr.stoptime
    FROM mimiciv_icu.icustays ie
    INNER JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE EXISTS (SELECT 1 FROM delirium_drugs dd WHERE LOWER(pr.drug) = dd.drug_name)
      AND pr.starttime IS NOT NULL
),

-- 步骤3: 预处理每小时的谵妄药物使用情况（优化版）
delirium_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        -- 简化：直接检查预过滤的谵妄药物记录是否与当前时间窗口重叠
    MAX(CASE WHEN dp.starttime <= co.endtime
                  AND COALESCE(dp.stoptime, co.endtime) >= co.starttime
             THEN 1 ELSE 0 END) AS on_delirium_med
    FROM co
    LEFT JOIN delirium_prescriptions_filtered dp ON co.stay_id = dp.stay_id
    GROUP BY co.stay_id, co.hr
),

-- 步骤4: 优化的GCS数据处理（使用临时表优化）
gcs_optimized AS (
    SELECT
        gcs.stay_id,
        gcs.charttime,
        -- GCS数据清洗：处理异常值
        CASE
            WHEN gcs.gcs < 3 THEN 3
            WHEN gcs.gcs > 15 THEN 15
            ELSE gcs.gcs
        END AS gcs,
        -- 高效判断GCS测量时刻的镇静状态：直接JOIN临时表
        CASE WHEN sh.has_sedation_infusion = 1 THEN 1 ELSE 0 END AS is_sedated
    FROM mimiciv_derived.gcs gcs
    INNER JOIN mimiciv_icu.icustays ie ON gcs.stay_id = ie.stay_id
    -- 直接JOIN临时表，避免复杂的LATERAL JOIN
    LEFT JOIN temp_sedation_hourly sh
        ON gcs.stay_id = sh.stay_id
        AND gcs.charttime >= sh.starttime
        AND gcs.charttime < sh.endtime
    WHERE gcs.gcs IS NOT NULL
),

-- =================================================================
-- BRAIN/神经系统 (整合版本：性能优化 + 使用临时表)
-- =================================================================
gcs AS (
    SELECT
        co.stay_id,
        co.hr,
        gcs_vals.gcs,
        -- 使用窗口函数优化：清晰表达"取最大值"语义 + 处理缺失值
        GREATEST(
            -- 分数来源1: GCS评分（缺失值默认为0分）
            CASE
                WHEN gcs_vals.gcs IS NULL THEN 0
                WHEN gcs_vals.gcs <= 5  THEN 4
                WHEN gcs_vals.gcs <= 8  THEN 3  -- GCS 6-8
                WHEN gcs_vals.gcs <= 12 THEN 2  -- GCS 9-12
                WHEN gcs_vals.gcs <= 14 THEN 1  -- GCS 13-14
                ELSE 0  -- GCS 15
            END,
            -- 分数来源2: 谵妄药物（SOFA2标准：任何谵妄药物至少得1分）
            CASE WHEN d.on_delirium_med = 1 THEN 1 ELSE 0 END
        ) AS brain
    FROM co
    -- 优化的LATERAL JOIN：从预处理的GCS表中查找
    LEFT JOIN LATERAL (
        SELECT gcs.gcs, gcs.is_sedated
        FROM gcs_optimized gcs
        WHERE gcs.stay_id = co.stay_id
          -- GCS测量时间必须在当前小时结束之前
          AND gcs.charttime <= co.endtime
        ORDER BY
          -- 优先级1: 当前小时内、非镇静的GCS（SOFA2：镇静前最后一次GCS）
          CASE WHEN gcs.charttime >= co.starttime AND gcs.is_sedated = 0 THEN 0 ELSE 1 END,
          -- 优先级2: 任何非镇静的GCS（回溯逻辑核心）
          gcs.is_sedated,
          -- 优先级3: 时间最近（在满足前两个条件的前提下）
          gcs.charttime DESC
        LIMIT 1
    ) AS gcs_vals ON TRUE
    -- JOIN预处理好的谵妄药物状态，避免重复计算
    LEFT JOIN delirium_hourly d ON co.stay_id = d.stay_id AND co.hr = d.hr
),

-- =================================================================
-- 呼吸系统数据准备 (Temp Table 模式 - 极速版)
-- =================================================================

-- 1. 预计算呼吸支持时间段 (利用索引加速查找)
DROP TABLE IF EXISTS temp_vent_periods CASCADE;
CREATE TEMP TABLE temp_vent_periods AS
SELECT stay_id, starttime, endtime, ventilation_status
FROM mimiciv_derived.ventilation
WHERE ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy');
CREATE INDEX idx_temp_vent_periods ON temp_vent_periods (stay_id, starttime, endtime);
ANALYZE temp_vent_periods;

-- 性能监控：temp_vent_periods 统计
DO $$
DECLARE
    record_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO record_count FROM temp_vent_periods;
    RAISE NOTICE '✓ temp_vent_periods 创建完成: % 条记录', record_count;
END $$;

-- 2. 核心逻辑：SpO2 与 FiO2 的清洗与对齐 (修复 LOCF BUG)
DROP TABLE IF EXISTS temp_sf_ratios CASCADE;
CREATE TEMP TABLE temp_sf_ratios AS
WITH raw_timeline AS (
    -- A. 获取 SpO2 (只取有效值且 < 98%)
    SELECT stay_id, charttime, valuenum AS spo2, NULL::numeric AS fio2
    FROM mimiciv_icu.chartevents
    WHERE itemid = 220277 AND valuenum > 0 AND valuenum < 98

    UNION ALL

    -- B. 获取 FiO2 (来源1: ChartEvents - 修复小数单位问题)
    SELECT stay_id, charttime, NULL::numeric AS spo2,
           CASE
               WHEN valuenum <= 1.0 THEN valuenum * 100.0
               ELSE valuenum
           END AS fio2
    FROM mimiciv_icu.chartevents
    WHERE itemid = 223835 AND valuenum > 0

    UNION ALL

    -- C. 获取 FiO2 (来源2: Blood Gas - 补充数据)
    SELECT stay_id, charttime, NULL::numeric AS spo2, fio2
    FROM mimiciv_derived.bg
    WHERE fio2 IS NOT NULL
),
imputed AS (
    SELECT
        stay_id, charttime, spo2,
        -- 关键修复：加上 IGNORE NULLS 才能实现"向前填充"
        last_value(fio2) IGNORE NULLS OVER (
            PARTITION BY stay_id ORDER BY charttime
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS fio2_val
    FROM raw_timeline
)
SELECT
    stay_id, charttime,
    spo2 / (fio2_val / 100.0) AS sf_ratio -- 计算 SF 比值
FROM imputed
WHERE spo2 IS NOT NULL AND fio2_val IS NOT NULL;

CREATE INDEX idx_temp_sf_ratios ON temp_sf_ratios (stay_id, charttime);
ANALYZE temp_sf_ratios;

-- 性能监控：temp_sf_ratios 统计
DO $$
DECLARE
    record_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO record_count FROM temp_sf_ratios;
    RAISE NOTICE '✓ temp_sf_ratios 创建完成: % 条记录', record_count;
END $$;

-- =================================================================
-- 呼吸系统主查询 (逻辑整合 - 移除Lateral Join)
-- =================================================================

-- 1. 呼吸支持状态 (小时级)
vent_hourly AS (
    SELECT co.stay_id, co.hr, MAX(1) AS has_support
    FROM co
    JOIN temp_vent_periods vp
        ON co.stay_id = vp.stay_id
        AND vp.starttime < co.endtime AND vp.endtime > co.starttime
    GROUP BY co.stay_id, co.hr
),

-- 2. ECMO 状态 (小时级)
ecmo_hourly AS (
    SELECT co.stay_id, co.hr, MAX(1) AS on_ecmo
    FROM co
    JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id AND ce.charttime >= co.starttime AND ce.charttime < co.endtime
    WHERE ce.itemid IN (224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
                        229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
                        228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260)
    GROUP BY co.stay_id, co.hr
),

-- 3. PF Ratio 聚合 (小时级 - 移除 Lateral Join)
pf_hourly AS (
    SELECT
        co.stay_id, co.hr, MIN(bg.pao2fio2ratio) AS pf_min
    FROM co
    JOIN mimiciv_derived.bg bg
        ON co.subject_id = bg.subject_id
        AND bg.charttime >= co.starttime AND bg.charttime < co.endtime
    WHERE bg.specimen = 'ART.' AND bg.pao2fio2ratio IS NOT NULL
    GROUP BY co.stay_id, co.hr
),

-- 4. SF Ratio 聚合 (小时级 - 移除 Lateral Join)
sf_hourly AS (
    SELECT
        co.stay_id, co.hr, MIN(sf.sf_ratio) AS sf_min
    FROM co
    JOIN temp_sf_ratios sf
        ON co.stay_id = sf.stay_id
        AND sf.charttime >= co.starttime AND sf.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 5. 最终呼吸评分计算 (完全符合 JAMA 2025 SOFA-2)
respiratory AS (
    SELECT
        stay_id,
        hr,
        CASE
            -- 4分: ECMO (Respiratory Indication)
            WHEN COALESCE(ecmo.on_ecmo, 0) = 1 THEN 4

            -- 优先路径: PF Ratio
            WHEN pf.pf_min IS NOT NULL THEN
                CASE
                    WHEN pf.pf_min <= 75  AND COALESCE(vent.has_support, 0) = 1 THEN 4
                    WHEN pf.pf_min <= 150 AND COALESCE(vent.has_support, 0) = 1 THEN 3
                    WHEN pf.pf_min <= 225 THEN 2
                    WHEN pf.pf_min <= 300 THEN 1
                    ELSE 0
                END

            -- 替代路径: SF Ratio (仅当 PF 缺失)
            WHEN sf.sf_min IS NOT NULL THEN
                CASE
                    WHEN sf.sf_min <= 120 AND COALESCE(vent.has_support, 0) = 1 THEN 4
                    WHEN sf.sf_min <= 200 AND COALESCE(vent.has_support, 0) = 1 THEN 3
                    WHEN sf.sf_min <= 250 THEN 2
                    WHEN sf.sf_min <= 300 THEN 1
                    ELSE 0
                END

            -- 缺失数据
            ELSE 0
        END AS respiratory
    FROM co
    LEFT JOIN vent_hourly vent ON co.stay_id = vent.stay_id AND co.hr = vent.hr
    LEFT JOIN ecmo_hourly ecmo ON co.stay_id = ecmo.stay_id AND co.hr = ecmo.hr
    LEFT JOIN pf_hourly pf ON co.stay_id = pf.stay_id AND co.hr = pf.hr
    LEFT JOIN sf_hourly sf ON co.stay_id = sf.stay_id AND co.hr = sf.hr
),

-- =================================================================
-- 心血管系统数据准备 (Temp Table 优化)
-- =================================================================
-- =================================================================
-- 心血管系统数据准备 (Temp Table 模式)
-- =================================================================

-- 1. 创建机械支持临时表 (避免主查询扫描大表)
DROP TABLE IF EXISTS temp_mech_support CASCADE;
CREATE TEMP TABLE temp_mech_support AS
SELECT
    ce.stay_id,
    ce.charttime,
    -- ECMO
    CASE WHEN ce.itemid IN (
        224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
        229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
        228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
    ) THEN 1 ELSE 0 END AS is_ecmo,
    -- 其他所有机械支持 (合并为一个Flag，简化后续JOIN)
    CASE WHEN ce.itemid IN (
        -- IABP
        224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986,
        225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355, 225742,
        -- Impella
        228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671,
        228171, 228172, 228167, 228170, 224314, 224318, 229898,
        -- LVAD
        220128, 220125, 229899, 229900, 229256, 229258, 229264, 229250,
        229262, 229254, 229252, 229260,
        -- TandemHeart
        228223, 228226, 228219, 228225, 228222, 228224, 228203, 228227,
        -- RVAD
        229263, 229255, 229259, 229257, 229265, 229251, 229253, 229261,
        -- Generic
        229560, 229559, 228187, 228867
    ) THEN 1 ELSE 0 END AS is_other_mech
FROM mimiciv_icu.chartevents ce
WHERE ce.itemid IN (
    -- 请确保包含上述所有 itemid
    224660, 229270, 224322, 228154, 220128, 228223, 229263, 229560
    -- (...省略完整列表，请务必补全...)
);

CREATE INDEX idx_temp_mech_support ON temp_mech_support (stay_id, charttime);
ANALYZE temp_mech_support;

-- 性能监控：temp_mech_support 统计（机械支持数据）
DO $$
DECLARE
    record_count BIGINT;
    ecmo_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO record_count FROM temp_mech_support;
    SELECT COUNT(*) INTO ecmo_count FROM temp_mech_support WHERE is_ecmo = 1;
    RAISE NOTICE '✓ temp_mech_support 创建完成: % 条记录 (其中ECMO: % 条)', record_count, ecmo_count;
END $$;


-- =================================================================
-- 心血管系统主查询
-- =================================================================

WITH co AS (
    SELECT ih.stay_id, ie.hadm_id, ie.subject_id
        , hr
        , ih.endtime - INTERVAL '1 HOUR' AS starttime
        , ih.endtime
    FROM mimiciv_derived.icustay_hourly ih
    INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
),

-- 1. 机械支持聚合 (Join Temp Table)
mechanical_support_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(tms.is_ecmo) AS has_ecmo,
        MAX(tms.is_other_mech) AS has_other_mech -- 直接在这里聚合好
    FROM co
    LEFT JOIN temp_mech_support tms
        ON co.stay_id = tms.stay_id
        AND tms.charttime >= co.starttime
        AND tms.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 2. 生命体征 (MAP)
vitalsign_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(vs.mbp) AS mbp_min
    FROM co
    LEFT JOIN mimiciv_derived.vitalsign vs
        ON co.stay_id = vs.stay_id
        AND vs.charttime >= co.starttime
        AND vs.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 3. 血管活性药物
vasoactive_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(va.norepinephrine) AS rate_norepinephrine,
        MAX(va.epinephrine) AS rate_epinephrine,
        MAX(va.dopamine) AS rate_dopamine,
        MAX(va.dobutamine) AS rate_dobutamine,
        MAX(va.vasopressin) AS rate_vasopressin,
        MAX(va.phenylephrine) AS rate_phenylephrine,
        MAX(va.milrinone) AS rate_milrinone
    FROM co
    LEFT JOIN mimiciv_derived.vasoactive_agent va
        ON co.stay_id = va.stay_id
        AND va.starttime < co.endtime
        AND COALESCE(va.endtime, co.endtime) > co.starttime
    GROUP BY co.stay_id, co.hr
),

-- 4. 最终评分计算
cardiovascular AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- 4分条件 (按优先级排序)
            -- 4a: 任意机械循环支持 (直接使用聚合后的 flag)
            WHEN COALESCE(mech.has_ecmo, 0) = 1 OR COALESCE(mech.has_other_mech, 0) = 1 THEN 4
            -- 4b: NE+Epi总碱基剂量 > 0.4
            WHEN dose_calc.ne_epi_total_base_dose > 0.4 THEN 4
            -- 4c: 中剂量NE+Epi + 其他药物
            WHEN dose_calc.ne_epi_total_base_dose > 0.2 AND dose_calc.other_vasopressor_flag = 1 THEN 4
            -- 4d: 多巴胺单独 > 40
            WHEN dose_calc.dopamine_only_score = 4 THEN 4

            -- 3分条件
            -- 3a: NE+Epi > 0.2
            WHEN dose_calc.ne_epi_total_base_dose > 0.2 THEN 3
            -- 3b: NE+Epi > 0 + 其他药物
            WHEN dose_calc.ne_epi_total_base_dose > 0 AND dose_calc.other_vasopressor_flag = 1 THEN 3
            -- 3c: 多巴胺单独 20-40
            WHEN dose_calc.dopamine_only_score = 3 THEN 3

            -- 2分条件
            -- 2a: NE+Epi > 0
            WHEN dose_calc.ne_epi_total_base_dose > 0 THEN 2
            -- 2b: 其他药物
            WHEN dose_calc.other_vasopressor_flag = 1 THEN 2
            -- 2c: 多巴胺单独 <= 20
            WHEN dose_calc.dopamine_only_score = 2 THEN 2

            -- 保底条件: 无药物时的 MAP 分级 (SOFA-2 Alternative)
            WHEN dose_calc.ne_epi_total_base_dose = 0
                 AND dose_calc.other_vasopressor_flag = 0
                 AND dose_calc.dopamine_only_score = 0 THEN
                CASE
                    WHEN vit.mbp_min < 40 THEN 4
                    WHEN vit.mbp_min < 50 THEN 3
                    WHEN vit.mbp_min < 60 THEN 2
                    WHEN vit.mbp_min < 70 THEN 1
                    ELSE 0
                END

            ELSE 0
        END AS cardiovascular
    FROM co
    LEFT JOIN mechanical_support_hourly mech ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN vitalsign_hourly vit ON co.stay_id = vit.stay_id AND co.hr = vit.hr
    LEFT JOIN vasoactive_hourly vaso ON co.stay_id = vaso.stay_id AND co.hr = vaso.hr
    
    -- 计算剂量逻辑 (已修复列引用错误)
    CROSS JOIN LATERAL (
        SELECT
            -- 1. NE/Epi 总碱基剂量
            (COALESCE(vaso.rate_norepinephrine, 0) / 2.0 + COALESCE(vaso.rate_epinephrine, 0)) AS ne_epi_total_base_dose,
            
            -- 2. 多巴胺单独使用评分
            CASE
                WHEN COALESCE(vaso.rate_dopamine, 0) > 0
                     AND COALESCE(vaso.rate_norepinephrine, 0) = 0
                     AND COALESCE(vaso.rate_epinephrine, 0) = 0
                     AND COALESCE(vaso.rate_dobutamine, 0) = 0
                     AND COALESCE(vaso.rate_vasopressin, 0) = 0
                     AND COALESCE(vaso.rate_phenylephrine, 0) = 0
                     AND COALESCE(vaso.rate_milrinone, 0) = 0
                THEN
                    CASE
                        WHEN vaso.rate_dopamine > 40 THEN 4
                        WHEN vaso.rate_dopamine > 20 THEN 3
                        WHEN vaso.rate_dopamine > 0 THEN 2
                        ELSE 0
                    END
                ELSE 0
            END AS dopamine_only_score,
            
            -- 3. 其他血管活性药标志 (包含多巴胺混用的情况)
            CASE WHEN (COALESCE(vaso.rate_dobutamine, 0) > 0
                       OR COALESCE(vaso.rate_vasopressin, 0) > 0
                       OR COALESCE(vaso.rate_phenylephrine, 0) > 0
                       OR COALESCE(vaso.rate_milrinone, 0) > 0)
                    -- 如果多巴胺存在，但并非"单独使用"(即有混用)，则视为"其他药物"
                    OR (COALESCE(vaso.rate_dopamine, 0) > 0 AND (
                        COALESCE(vaso.rate_epinephrine, 0) > 0
                        OR COALESCE(vaso.rate_norepinephrine, 0) > 0
                        OR COALESCE(vaso.rate_dobutamine, 0) > 0
                        OR COALESCE(vaso.rate_vasopressin, 0) > 0
                        OR COALESCE(vaso.rate_phenylephrine, 0) > 0
                        OR COALESCE(vaso.rate_milrinone, 0) > 0))
                THEN 1 ELSE 0
            END AS other_vasopressor_flag
    ) dose_calc
),

-- 步骤4: 预处理胆红素数据 (高性能优化)
bilirubin_data AS (
    SELECT
        stay.stay_id,
        enz.charttime,
        enz.bilirubin_total
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.enzyme enz ON stay.hadm_id = enz.hadm_id
    -- 关键修复：约束胆红素时间在ICU住院时段内，避免跨住院污染
    WHERE enz.bilirubin_total IS NOT NULL
      AND enz.charttime >= stay.intime
      AND enz.charttime <= stay.outtime
),

-- =================================================================
-- LIVER/肝脏 (SOFA2标准：高性能预聚合版本)
-- =================================================================
liver AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MAX(bd.bilirubin_total) > 12.0 THEN 4
            WHEN MAX(bd.bilirubin_total) > 6.0 AND MAX(bd.bilirubin_total) <= 12.0 THEN 3
            WHEN MAX(bd.bilirubin_total) > 3.0 AND MAX(bd.bilirubin_total) <= 6.0 THEN 2
            WHEN MAX(bd.bilirubin_total) > 1.2 AND MAX(bd.bilirubin_total) <= 3.0 THEN 1
            WHEN MAX(bd.bilirubin_total) IS NULL THEN NULL
            ELSE 0
        END AS liver
    FROM co
    LEFT JOIN bilirubin_data bd
        ON co.stay_id = bd.stay_id
        AND bd.charttime >= co.starttime
        AND bd.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 步骤5: 预处理肾脏数据 (修复逻辑错误版本)

-- 基础数据预处理
chemistry_data AS (
    SELECT
        stay.stay_id,
        chem.charttime,
        chem.creatinine
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.chemistry chem ON stay.hadm_id = chem.hadm_id
    -- 关键修复：约束肌酐时间在ICU住院时段内，避免跨住院污染
    WHERE chem.creatinine IS NOT NULL
      AND chem.charttime >= stay.intime
      AND chem.charttime <= stay.outtime
),
bg_data AS (
    SELECT
        stay.stay_id,
        bg.charttime,
        bg.ph,
        bg.potassium,
        bg.bicarbonate
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.bg bg ON stay.subject_id = bg.subject_id
    -- 关键修复：约束血气数据时间在ICU住院时段内，避免跨住院污染
    WHERE bg.specimen = 'ART.'
      AND bg.charttime >= stay.intime
      AND bg.charttime <= stay.outtime
),

-- Step 1: 为每个stay_id查找最佳体重（多层次查找策略）
patient_weights AS (
    SELECT
        icu.stay_id,
        -- 优先级1：使用ICU期间记录的体重（最准确）
        COALESCE(
            -- 查找该ICU住院期间的任意体重记录
            (SELECT wd.weight
             FROM mimiciv_derived.weight_durations wd
             WHERE wd.stay_id = icu.stay_id
             AND wd.weight IS NOT NULL
             AND wd.weight > 0
             ORDER BY wd.starttime
             LIMIT 1),
            -- 优先级2：如果没有ICU体重，使用该患者历史体重的中位数
            (SELECT AVG(wd.weight)
             FROM mimiciv_derived.weight_durations wd
             WHERE wd.stay_id IN (
                 SELECT icu2.stay_id
                 FROM mimiciv_icu.icustays icu2
                 WHERE icu2.subject_id = icu.subject_id
             )
             AND wd.weight IS NOT NULL
             AND wd.weight > 0),
            -- 优先级3：基于性别和年龄的估算体重（临床常用公式）
            CASE
                WHEN p.gender = 'M' THEN  -- 男性
                    CASE
                        WHEN p.anchor_age < 20 THEN 65.0
                        WHEN p.anchor_age < 40 THEN 70.0
                        WHEN p.anchor_age < 60 THEN 75.0
                        WHEN p.anchor_age < 80 THEN 70.0
                        ELSE 65.0
                    END
                WHEN p.gender = 'F' THEN  -- 女性
                    CASE
                        WHEN p.anchor_age < 20 THEN 55.0
                        WHEN p.anchor_age < 40 THEN 60.0
                        WHEN p.anchor_age < 60 THEN 65.0
                        WHEN p.anchor_age < 80 THEN 60.0
                        ELSE 55.0
                    END
                ELSE 70.0  -- 性别未知时的默认值
            END,
            -- 优先级4：最终默认值（临床标准默认体重）
            70.0
        ) AS patient_weight
    FROM mimiciv_icu.icustays icu
    LEFT JOIN mimiciv_hosp.patients p ON icu.subject_id = p.subject_id
),

-- Step 2: 计算真实每小时尿量(ml/kg/hr) - 使用最佳体重数据
urine_output_raw AS (
    SELECT
        uo.stay_id,
        uo.charttime,
        -- 使用多层次查找的最佳体重
        uo.urineoutput / pw.patient_weight as urine_ml_per_kg,
        icu.intime,
        pw.patient_weight  -- 保留体重信息用于验证
    FROM mimiciv_derived.urine_output uo
    JOIN patient_weights pw ON uo.stay_id = pw.stay_id
    LEFT JOIN mimiciv_icu.icustays icu ON uo.stay_id = icu.stay_id
    WHERE uo.urineoutput IS NOT NULL
),

-- Step 2: 创建每小时时间序列（确保所有小时都有记录）
hourly_timeline AS (
    SELECT
        stay_id,
        intime,
        outtime,
        generate_series(
            0,
            FLOOR(EXTRACT(EPOCH FROM (outtime - intime))/3600)::integer
        ) AS hr
    FROM mimiciv_icu.icustays
),

-- Step 3: 计算每个小时的尿量（聚合该小时内的所有尿量记录）
urine_output_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        co.intime,
        co.outtime,
        SUM(uo.urine_ml_per_kg) as uo_ml_kg_hr
    FROM hourly_timeline co
    LEFT JOIN urine_output_raw uo
        ON co.stay_id = uo.stay_id
        AND uo.charttime >= co.intime + INTERVAL '1 hour' * co.hr
        AND uo.charttime < co.intime + INTERVAL '1 hour' * (co.hr + 1)
    GROUP BY co.stay_id, co.hr, co.intime, co.outtime
),

-- Step 4: 使用滑动窗口计算6h、12h、24h累计尿量和平均尿量
urine_output_sliding_windows AS (
    SELECT
        stay_id,
        hr,
        uo_ml_kg_hr,
        -- 6小时滑动窗口：必须存在完整6个小时的观测才计算平均
        CASE
            WHEN COUNT(uo_ml_kg_hr) OVER w6 = 6
            THEN SUM(uo_ml_kg_hr) OVER w6 / 6.0
            ELSE NULL
        END AS uo_avg_6h,

        -- 12小时滑动窗口：同理需要完整12小时数据
        CASE
            WHEN COUNT(uo_ml_kg_hr) OVER w12 = 12
            THEN SUM(uo_ml_kg_hr) OVER w12 / 12.0
            ELSE NULL
        END AS uo_avg_12h,

        -- 24小时滑动窗口：仅当24个连续小时均有尿量记录时才计算
        CASE
            WHEN COUNT(uo_ml_kg_hr) OVER w24 = 24
            THEN SUM(uo_ml_kg_hr) OVER w24 / 24.0
            ELSE NULL
        END AS uo_avg_24h
    FROM urine_output_hourly
    WINDOW
        w6 AS (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 5 PRECEDING AND 0 FOLLOWING
        ),
        w12 AS (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 11 PRECEDING AND 0 FOLLOWING
        ),
        w24 AS (
            PARTITION BY stay_id
            ORDER BY hr
            ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING
        )
),

-- 注释：删除复杂的Gaps and Islands算法
-- SOFA2标准要求的"持续X小时"指的是时间窗口内的平均值，而非连续每小时达标
-- 使用前一步的滑动窗口平均值直接进行评分更符合临床实际

-- RRT状态预处理：将RRT疗程在首末记录之间视为持续活跃
rrt_event_hours AS (
    SELECT
        stay.stay_id,
        FLOOR(EXTRACT(EPOCH FROM (rrt.charttime - stay.intime))/3600) AS event_hr
    FROM mimiciv_derived.rrt rrt
    JOIN mimiciv_icu.icustays stay ON rrt.stay_id = stay.stay_id
    WHERE rrt.dialysis_present = 1
),
rrt_event_bounds AS (
    SELECT
        stay_id,
        MIN(event_hr) AS first_rrt_hr,
        MAX(event_hr) AS last_rrt_hr
    FROM rrt_event_hours
    GROUP BY stay_id
),
rrt_status AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN reb.first_rrt_hr IS NOT NULL
                 AND co.hr BETWEEN reb.first_rrt_hr AND COALESCE(reb.last_rrt_hr, reb.first_rrt_hr)
            THEN 1 ELSE 0
        END AS rrt_active
    FROM co
    LEFT JOIN rrt_event_bounds reb ON co.stay_id = reb.stay_id
),

-- =================================================================
-- KIDNEY/肾脏 (SOFA2标准：分层聚合版本)
-- =================================================================
kidney_hourly_aggregates AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(chem.creatinine) AS creatinine_max,
        MAX(bg.potassium) AS potassium_max,
        MIN(bg.ph) AS ph_min,
        MIN(bg.bicarbonate) AS bicarbonate_min,
        -- 删除复杂的连续时间计算，直接使用滑动窗口平均值
        -- 滑动窗口数据（6h、12h、24h平均尿量）
        MAX(uo.uo_avg_6h) AS uo_avg_6h_max,
        MAX(uo.uo_avg_12h) AS uo_avg_12h_max,
        MAX(uo.uo_avg_24h) AS uo_avg_24h_max,
        MAX(CASE WHEN rrt.rrt_active = 1 THEN 1 ELSE 0 END) AS rrt_active_flag
    FROM co
    LEFT JOIN chemistry_data chem
        ON co.stay_id = chem.stay_id
        AND chem.charttime >= co.starttime
        AND chem.charttime < co.endtime
    LEFT JOIN bg_data bg
        ON co.stay_id = bg.stay_id
        AND bg.charttime >= co.starttime
        AND bg.charttime < co.endtime
    LEFT JOIN rrt_status rrt ON co.stay_id = rrt.stay_id AND co.hr = rrt.hr
    LEFT JOIN urine_output_sliding_windows uo ON co.stay_id = uo.stay_id AND co.hr = uo.hr
    GROUP BY co.stay_id, co.hr
),
kidney AS (
    SELECT
        stay_id,
        hr,
        GREATEST(
            CASE WHEN rrt_active_flag = 1 THEN 4 ELSE 0 END,
            CASE
                WHEN (
                    creatinine_max > 1.2
                    OR (uo_avg_6h_max IS NOT NULL AND uo_avg_6h_max < 0.3)
                )
                     AND (COALESCE(potassium_max, 0) >= 6.0
                          OR (COALESCE(ph_min, 7.4) <= 7.2 AND COALESCE(bicarbonate_min, 24) <= 12))
                THEN 4 ELSE 0 END,
            CASE
                WHEN creatinine_max > 3.5 THEN 3
                WHEN creatinine_max > 2.0 THEN 2
                WHEN creatinine_max > 1.2 THEN 1
                ELSE 0 END,
            -- 尿量评分（SOFA2标准：简化版，基于滑动窗口平均尿量）
            CASE
                -- 3分：<0.3 mL/kg/h 的24小时滑动平均值（SOFA2：持续24小时）
                WHEN uo_avg_24h_max IS NOT NULL AND uo_avg_24h_max < 0.3 THEN 3
                -- 2分：<0.5 mL/kg/h 的12小时滑动平均值（SOFA2：持续≥12小时）
                WHEN uo_avg_12h_max IS NOT NULL AND uo_avg_12h_max < 0.5 THEN 2
                -- 1分：<0.5 mL/kg/h 的6小时滑动平均值（SOFA2：持续6-12小时）
                WHEN uo_avg_6h_max IS NOT NULL AND uo_avg_6h_max < 0.5 THEN 1
                ELSE 0 END
        ) AS kidney
    FROM kidney_hourly_aggregates
),

-- 步骤6: 预处理血小板数据 (高性能优化)
platelet_data AS (
    SELECT
        stay.stay_id,
        cbc.charttime,
        cbc.platelet
    FROM mimiciv_icu.icustays stay
    JOIN mimiciv_derived.complete_blood_count cbc ON stay.hadm_id = cbc.hadm_id
    -- 关键修复：约束血小板时间在ICU住院时段内，避免跨住院污染
    WHERE cbc.platelet IS NOT NULL
      AND cbc.charttime >= stay.intime
      AND cbc.charttime <= stay.outtime
),

-- =================================================================
-- HEMOSTASIS/凝血 (SOFA2标准：高性能预聚合版本)
-- =================================================================
hemostasis AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN MIN(pd.platelet) <= 50 THEN 4
            WHEN MIN(pd.platelet) <= 80 THEN 3
            WHEN MIN(pd.platelet) <= 100 THEN 2
            WHEN MIN(pd.platelet) <= 150 THEN 1
            WHEN MIN(pd.platelet) IS NULL THEN NULL
            ELSE 0
        END AS hemostasis
    FROM co
    LEFT JOIN platelet_data pd
        ON co.stay_id = pd.stay_id
        AND pd.charttime >= co.starttime
        AND pd.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- 综合评分 (参考SOFA1的窗口函数实现)
-- =================================================================
score_final AS (
    SELECT s.*
        -- 各组件24小时窗口最差值
        , COALESCE(MAX(brain) OVER w, 0) AS brain_24hours
        , COALESCE(MAX(respiratory) OVER w, 0) AS respiratory_24hours
        , COALESCE(MAX(cardiovascular) OVER w, 0) AS cardiovascular_24hours
        , COALESCE(MAX(liver) OVER w, 0) AS liver_24hours
        , COALESCE(MAX(kidney) OVER w, 0) AS kidney_24hours
        , COALESCE(MAX(hemostasis) OVER w, 0) AS hemostasis_24hours
        -- SOFA2总分
        , COALESCE(MAX(brain) OVER w, 0) + COALESCE(MAX(respiratory) OVER w, 0) +
         COALESCE(MAX(cardiovascular) OVER w, 0) + COALESCE(MAX(liver) OVER w, 0) +
         COALESCE(MAX(kidney) OVER w, 0) + COALESCE(MAX(hemostasis) OVER w, 0) AS sofa2_24hours
    FROM (
        SELECT co.stay_id, co.hadm_id, co.subject_id, co.hr, co.starttime, co.endtime,
               gcs.brain, respiratory.respiratory, cardiovascular.cardiovascular,
               liver.liver, kidney.kidney, hemostasis.hemostasis
        FROM co
        LEFT JOIN gcs ON co.stay_id = gcs.stay_id AND co.hr = gcs.hr
        LEFT JOIN respiratory ON co.stay_id = respiratory.stay_id AND co.hr = respiratory.hr
        LEFT JOIN cardiovascular ON co.stay_id = cardiovascular.stay_id AND co.hr = cardiovascular.hr
        LEFT JOIN liver ON co.stay_id = liver.stay_id AND co.hr = liver.hr
        LEFT JOIN kidney ON co.stay_id = kidney.stay_id AND co.hr = kidney.hr
        LEFT JOIN hemostasis ON co.stay_id = hemostasis.stay_id AND co.hr = hemostasis.hr
    ) s
    WINDOW w AS (PARTITION BY stay_id ORDER BY hr ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING)
)

-- =================================================================
-- 创建表并插入数据（优化：删除冗余SELECT，避免重复计算）
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores CASCADE;

CREATE TABLE mimiciv_derived.sofa2_scores AS
SELECT
    stay_id,
    hadm_id,
    subject_id,
    hr,
    starttime,
    endtime,
    -- SOFA2标准：24小时窗口最差评分
    brain_24hours AS brain,
    respiratory_24hours AS respiratory,
    cardiovascular_24hours AS cardiovascular,
    liver_24hours AS liver,
    kidney_24hours AS kidney,
    hemostasis_24hours AS hemostasis,
    sofa2_24hours AS sofa2_total
FROM score_final
WHERE hr >= 0;

-- 添加主键和索引以提高查询性能
ALTER TABLE mimiciv_derived.sofa2_scores
ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;

CREATE INDEX idx_sofa2_stay_id ON mimiciv_derived.sofa2_scores(stay_id);
CREATE INDEX idx_sofa2_subject_id ON mimiciv_derived.sofa2_scores(subject_id);
CREATE INDEX idx_sofa2_hadm_id ON mimiciv_derived.sofa2_scores(hadm_id);
CREATE INDEX idx_sofa2_total_score ON mimiciv_derived.sofa2_scores(sofa2_total);

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.sofa2_scores IS 'SOFA2评分系统结果表，包含每小时评分和24小时窗口最差评分';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.stay_id IS 'ICU住院ID';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.hadm_id IS '住院ID';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.subject_id IS '患者ID';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.hr IS 'ICU住院小时数';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.brain IS '神经系统评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.respiratory IS '呼吸系统评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.cardiovascular IS '心血管系统评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.liver IS '肝脏系统评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.kidney IS '肾脏系统评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.hemostasis IS '凝血系统评分(0-4)';
COMMENT ON COLUMN mimiciv_derived.sofa2_scores.sofa2_total IS 'SOFA2总分(0-24)';

-- 可选：如需查看结果，可查询新建的表
-- SELECT * FROM mimiciv_derived.sofa2_scores ORDER BY stay_id, hr LIMIT 100;

-- 性能监控：最终结果统计
DO $$
DECLARE
    completion_time TIMESTAMP := clock_timestamp();
    total_records BIGINT;
BEGIN
    SELECT COUNT(*) INTO total_records FROM mimiciv_derived.sofa2_scores;
    RAISE NOTICE '=== SOFA2评分表创建完成: %，总记录数: % ===',
                 completion_time, total_records;
END $$;

-- 显示创建结果统计
SELECT
    'SOFA2评分表创建完成' AS status,
    COUNT(*) AS total_records,
    COUNT(DISTINCT stay_id) AS unique_stays,
    COUNT(DISTINCT subject_id) AS unique_patients,
    MIN(sofa2_total) AS min_score,
    MAX(sofa2_total) AS max_score,
    ROUND(AVG(sofa2_total), 2) AS avg_score,
    LOCALTIMESTAMP AS completion_time
FROM mimiciv_derived.sofa2_scores;
