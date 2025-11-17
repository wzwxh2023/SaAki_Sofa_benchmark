-- =================================================================
-- SOFA-2 评分系统优化版本
-- 参考SOFA1的简洁结构，实现SOFA2最新标准
-- =================================================================

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
-- 预处理步骤 (Staging CTEs)
-- =================================================================

-- 步骤1: 预处理药物列表（统一维护，避免重复）
drug_params AS (
    SELECT UNNEST(ARRAY[
        '%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
        '%fentanyl%', '%remifentanil%', '%morphine%', '%hydromorphone%',
        '%dexmedetomidine%', '%ketamine%', '%clonidine%', '%etomidate%'
    ]) AS sedation_pattern
),
delirium_params AS (
    SELECT UNNEST(ARRAY[
        '%haloperidol%', '%haldol%', '%quetiapine%', '%seroquel%',
        '%olanzapine%', '%zyprexa%', '%risperidone%', '%risperdal%',
        '%ziprasidone%', '%geodon%', '%clozapine%', '%aripiprazole%'
    ]) AS delirium_pattern
),

-- 步骤2: 预处理所有GCS测量值，包括数据清洗和镇静状态标记
gcs_stg AS (
    SELECT
        gcs.stay_id,
        gcs.charttime,
        -- GCS数据清洗：处理异常值
        CASE
            WHEN gcs.gcs < 3 THEN 3
            WHEN gcs.gcs > 15 THEN 15
            ELSE gcs.gcs
        END AS gcs,
        -- 判断在GCS测量时刻，是否有镇静药物在输注
        MAX(
            CASE
                WHEN pr.starttime <= gcs.charttime
                     AND COALESCE(pr.stoptime, gcs.charttime + INTERVAL '1 minute') > gcs.charttime
                     AND EXISTS (
                        SELECT 1
                        FROM drug_params dp
                        WHERE LOWER(pr.drug) LIKE dp.sedation_pattern
                     )
                THEN 1 ELSE 0
            END
        ) AS is_sedated
    FROM mimiciv_derived.gcs gcs
    -- 提前与icustays和prescriptions连接，避免LATERAL中重复连接
    INNER JOIN mimiciv_icu.icustays ie ON gcs.stay_id = ie.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE gcs.gcs IS NOT NULL
    GROUP BY gcs.stay_id, gcs.charttime, gcs.gcs
),

-- 步骤3: 预处理每小时的谵妄药物使用情况
delirium_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(
            CASE
                WHEN pr.starttime <= co.endtime
                     AND COALESCE(pr.stoptime, co.endtime) >= co.starttime
                     AND EXISTS (
                        SELECT 1
                        FROM delirium_params dp
                        WHERE LOWER(pr.drug) LIKE dp.delirium_pattern
                     )
                THEN 1 ELSE 0
            END
        ) AS on_delirium_med
    FROM co
    INNER JOIN mimiciv_icu.icustays ie ON co.stay_id = ie.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- BRAIN/神经系统 (整合版本：性能优化 + 逻辑清晰)
-- =================================================================
gcs AS (
    SELECT
        co.stay_id,
        co.hr,
        gcs_vals.gcs,
        -- GREATEST函数：清晰表达"取最大值"语义 + 处理缺失值
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
    -- 高效LATERAL：从预处理的GCS表中查找
    LEFT JOIN LATERAL (
        SELECT gcs.gcs, gcs.is_sedated
        FROM gcs_stg gcs
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
-- 呼吸系统预计算CTEs (性能优化：预计算-连接-聚合模式)
-- =================================================================

-- 步骤1: 预计算所有PF比值 (血气分析)
pf_ratios_all AS (
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
        AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy')
    WHERE bg.specimen = 'ART.'
      AND bg.pao2fio2ratio IS NOT NULL
      AND bg.pao2fio2ratio > 0
),

-- 步骤2: 预计算SpO2和FiO2的原始数据
spo2_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        ce.valuenum AS spo2_value
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 220277  -- SpO2
      AND ce.valuenum > 0
      AND ce.valuenum < 98  -- SF ratio只在SpO2<98%时有效
),

fio2_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        ce.valuenum AS fio2_value  -- FiO2百分比 (21-100%)
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 223835  -- 正确的FiO2 itemid
      AND ce.valuenum BETWEEN 21 AND 100  -- FiO2百分比范围
),

-- 步骤3: 预计算所有SF比值 (SpO2:FiO2) - 简化版本
sf_ratios_all AS (
    SELECT
        spo2.stay_id,
        spo2.charttime,
        (spo2.spo2_value / (fio2.fio2_value / 100.0)) AS oxygen_ratio,  -- 关键修复：百分比转小数
        -- 简化的呼吸支持检测：直接JOIN ventilation表
        CASE WHEN vd.stay_id IS NOT NULL THEN 1 ELSE 0 END AS has_advanced_support
    FROM spo2_raw spo2
    INNER JOIN fio2_raw fio2
        ON spo2.stay_id = fio2.stay_id
        AND fio2.charttime BETWEEN spo2.charttime - INTERVAL '1 hour' AND spo2.charttime  -- 统一向前看1小时
    -- 直接LEFT JOIN ventilation表，简化复杂的LATERAL JOIN
    LEFT JOIN mimiciv_derived.ventilation vd
        ON spo2.stay_id = vd.stay_id
        AND spo2.charttime BETWEEN vd.starttime AND vd.endtime  -- 标准的时间点-区间匹配
        AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy')
    WHERE spo2.spo2_value IS NOT NULL
      AND fio2.fio2_value IS NOT NULL
),

-- 步骤4: 预计算所有ECMO记录（与循环系统保持一致）
ecmo_events AS (
    -- 方法1: ECMO设备记录（完整覆盖，与循环系统一致）
    SELECT
        ce.stay_id,
        ce.charttime,
        1 AS ecmo_indicator
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (
        -- ECMO相关itemid (基于实际数据验证，与循环系统完全一致)
        224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
        229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
        228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
    )

    UNION ALL

    -- 方法2: ECMO操作程序
    SELECT
        pe.stay_id,
        pe.starttime AS charttime,
        1 AS ecmo_indicator
    FROM mimiciv_icu.procedureevents pe
    WHERE pe.itemid IN (229529, 229530)  -- ECMO相关操作
),

-- =================================================================
-- 步骤5: 小时级PF数据聚合 (仅包含PF比值)
pf_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(pf.oxygen_ratio) AS pf_ratio_min,
        MAX(pf.has_advanced_support) AS pf_has_support
    FROM co
    LEFT JOIN pf_ratios_all pf
        ON co.stay_id = pf.stay_id
        AND pf.charttime >= co.starttime
        AND pf.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- 步骤6: 小时级SF数据聚合 (仅包含SF比值)
sf_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MIN(sf.oxygen_ratio) AS sf_ratio_min,
        MAX(sf.has_advanced_support) AS sf_has_support
    FROM co
    LEFT JOIN sf_ratios_all sf
        ON co.stay_id = sf.stay_id
        AND sf.charttime >= co.starttime
        AND sf.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- 呼吸系统小时级聚合 (在JOIN层面严格执行PF优先原则)
-- =================================================================
respiratory_hourly AS (
    SELECT
        co.stay_id,
        co.hr,

        -- ECMO状态：小时内是否有ECMO
        COALESCE(MAX(ecmo.ecmo_indicator), 0) AS on_ecmo,

        -- 氧合指数类型：严格PF优先
        CASE
            WHEN MAX(pf.pf_ratio_min) IS NOT NULL THEN 'PF'
            WHEN MAX(sf.sf_ratio_min) IS NOT NULL THEN 'SF'
            ELSE NULL
        END AS ratio_type,

        -- 氧合指数值：严格对应的PF或SF值
        COALESCE(MAX(pf.pf_ratio_min), MAX(sf.sf_ratio_min)) AS oxygen_ratio,

        -- 呼吸支持状态：必须与氧合指数类型匹配！
        CASE
            WHEN MAX(pf.pf_ratio_min) IS NOT NULL THEN MAX(pf.pf_has_support)  -- PF对应的支持状态
            WHEN MAX(sf.sf_ratio_min) IS NOT NULL THEN MAX(sf.sf_has_support)  -- SF对应的支持状态
            ELSE 0
        END AS has_advanced_support

    FROM co
    -- 先连接小时级PF数据
    LEFT JOIN pf_hourly pf
        ON co.stay_id = pf.stay_id AND co.hr = pf.hr
    -- 只有当该小时没有PF数据时，才考虑SF数据
    LEFT JOIN sf_hourly sf
        ON co.stay_id = sf.stay_id
        AND co.hr = sf.hr
        AND pf.pf_ratio_min IS NULL  -- 关键：仅当无PF时才连接SF
    -- 时间窗口连接：ECMO事件
    LEFT JOIN ecmo_events ecmo
        ON co.stay_id = ecmo.stay_id
        AND ecmo.charttime >= co.starttime
        AND ecmo.charttime < co.endtime
    GROUP BY co.stay_id, co.hr
),

-- =================================================================
-- RESPIRATORY/呼吸系统 (SOFA2标准：最终评分计算)
-- =================================================================
respiratory AS (
    SELECT
        stay_id,
        hr,
        CASE
            -- 4分: ECMO
            WHEN on_ecmo = 1 THEN 4
            -- 4分: 最严重低氧血症 + 呼吸支持
            WHEN oxygen_ratio <=
                CASE WHEN ratio_type = 'SF' THEN 120 ELSE 75 END
                AND has_advanced_support = 1 THEN 4
            -- 3分: 重度低氧血症 + 呼吸支持
            WHEN oxygen_ratio <=
                CASE WHEN ratio_type = 'SF' THEN 200 ELSE 150 END
                AND has_advanced_support = 1 THEN 3
            -- 2分: 中度低氧血症
            WHEN oxygen_ratio <=
                CASE WHEN ratio_type = 'SF' THEN 250 ELSE 225 END THEN 2
            -- 1分: 轻度低氧血症
            WHEN oxygen_ratio <= 300 THEN 1
            -- 0分: 正常或缺失数据
            WHEN oxygen_ratio > 300 OR oxygen_ratio IS NULL THEN 0
            ELSE 0
        END AS respiratory
    FROM respiratory_hourly
),

-- =================================================================
-- 预处理CTEs：解决LATERAL JOIN性能问题
-- =================================================================

-- 步骤1: 预处理机械支持（基于实际MIMIC-IV数据）
mechanical_support_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(CASE WHEN ce.itemid IN (
            -- ECMO相关itemid (基于实际数据验证)
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260
        ) THEN 1 ELSE 0 END) AS has_ecmo,
        MAX(CASE WHEN ce.itemid IN (
            -- IABP相关itemid (基于实际数据验证)
            224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986,
            225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355,
            225742
        ) THEN 1 ELSE 0 END) AS has_iabp,
        MAX(CASE WHEN ce.itemid IN (
            -- Impella相关itemid (基于实际数据验证，移除重复的227355)
            228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897, 229671,
            228171, 228172, 228167, 228170, 224314, 224318, 229898
        ) THEN 1 ELSE 0 END) AS has_impella,
        MAX(CASE WHEN ce.itemid IN (
            -- LVAD相关itemid (基于实际数据验证 + 新发现的LVAD变体)
            229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260, 220128,
            220125, 229899, 229900
        ) THEN 1 ELSE 0 END) AS has_lvad,
        MAX(CASE WHEN ce.itemid IN (
            -- TandemHeart设备 (新发现)
            228223, 228226, 228219, 228225, 228222, 228224, 228203, 228227
        ) THEN 1 ELSE 0 END) AS has_tandemheart,
        MAX(CASE WHEN ce.itemid IN (
            -- RVAD设备 (新发现)
            229263, 229255, 229259, 229257, 229265, 229251, 229253, 229261
        ) THEN 1 ELSE 0 END) AS has_rvad,
        MAX(CASE WHEN ce.itemid IN (
            -- 通用心脏辅助设备 (新发现)
            229560, 229559, 228187, 228867
        ) THEN 1 ELSE 0 END) AS has_cardiac_assist
    FROM co
    LEFT JOIN mimiciv_icu.chartevents ce
        ON co.stay_id = ce.stay_id
        AND ce.charttime >= co.starttime
        AND ce.charttime < co.endtime
        AND ce.itemid IN (
            -- 完整的机械支持itemid列表（已去重，共88个）
            -- ECMO (25个)
            224660, 229270, 229272, 229268, 229271, 229277, 229278, 229280, 229276,
            229274, 229266, 229363, 229364, 229365, 229269, 229275, 229267, 229273,
            228193, 229256, 229258, 229264, 229250, 229262, 229254, 229252, 229260,
            -- IABP (17个)
            224322, 227980, 225988, 228866, 225339, 225982, 226110, 225985, 225986,
            225341, 225981, 225979, 225987, 225342, 225984, 225980, 227754, 227355,
            225742,
            -- Impella (16个，移除重复的227355)
            228154, 229679, 228173, 228164, 228162, 228174, 229680, 229897,
            229671, 228171, 228172, 228167, 228170, 224314, 224318, 229898,
            -- LVAD (12个，包含新发现的变体)
            220128, 220125, 229899, 229900, 229256, 229258, 229264, 229250,
            229262, 229254, 229252, 229260,
            -- TandemHeart (8个，新发现)
            228223, 228226, 228219, 228225, 228222, 228224, 228203, 228227,
            -- RVAD (8个，新发现)
            229263, 229255, 229259, 229257, 229265, 229251, 229253, 229261,
            -- 通用心脏辅助设备 (4个，新发现)
            229560, 229559, 228187, 228867
        )
    GROUP BY co.stay_id, co.hr
),

-- 步骤2: 预处理生命体征（MAP）
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

-- 步骤3: 预处理血管活性药物
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

-- =================================================================
-- CARDIOVASCULAR/心血管 (SOFA2标准：添加多巴胺特殊评分逻辑)
-- =================================================================
cardiovascular AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- 4分条件 (按优先级排序)
            -- 4a: 机械循环支持 (任一设备)
            WHEN COALESCE(mech.has_ecmo, 0) + COALESCE(mech.has_iabp, 0) +
                 COALESCE(mech.has_impella, 0) + COALESCE(mech.has_lvad, 0) +
                 COALESCE(mech.has_tandemheart, 0) + COALESCE(mech.has_rvad, 0) +
                 COALESCE(mech.has_cardiac_assist, 0) > 0 THEN 4
            -- 4b: NE+Epi总碱基剂量 > 0.4 mcg/kg/min
            WHEN ne_epi_total_base_dose > 0.4 THEN 4
            -- 4c: NE+Epi > 0.2 且使用其他药物
            WHEN ne_epi_total_base_dose > 0.2 AND other_vasopressor_flag = 1 THEN 4
            -- 4d: 多巴胺单独使用 > 40 μg/kg/min
            WHEN dopamine_only_score >= 4 THEN 4

            -- 3分条件 (按优先级排序)
            -- 3a: NE+Epi总碱基剂量 > 0.2 mcg/kg/min
            WHEN ne_epi_total_base_dose > 0.2 THEN 3
            -- 3b: NE+Epi > 0 且使用其他药物
            WHEN ne_epi_total_base_dose > 0 AND other_vasopressor_flag = 1 THEN 3
            -- 3c: 多巴胺单独使用 > 20-40 μg/kg/min
            WHEN dopamine_only_score = 3 THEN 3

            -- 2分条件 (按优先级排序)
            -- 2a: NE+Epi总碱基剂量 > 0
            WHEN ne_epi_total_base_dose > 0 THEN 2
            -- 2b: 使用其他血管活性药物（不包括多巴胺单独使用）
            WHEN other_vasopressor_flag = 1 THEN 2
            -- 2c: 多巴胺单独使用 ≤ 20 μg/kg/min
            WHEN dopamine_only_score = 2 THEN 2

            -- 1分条件: MAP < 70 mmHg 且无血管活性药物
            WHEN vit.mbp_min < 70 AND ne_epi_total_base_dose = 0
                 AND other_vasopressor_flag = 0 AND dopamine_only_score = 0 THEN 1

            -- 0分条件: MAP >= 70 mmHg 或正常情况
            ELSE 0
        END AS cardiovascular
    FROM co
    -- 高性能连接：直接JOIN预聚合数据，避免LATERAL
    LEFT JOIN mechanical_support_hourly mech ON co.stay_id = mech.stay_id AND co.hr = mech.hr
    LEFT JOIN vitalsign_hourly vit ON co.stay_id = vit.stay_id AND co.hr = vit.hr
    LEFT JOIN vasoactive_hourly vaso ON co.stay_id = vaso.stay_id AND co.hr = vaso.hr
    -- 计算所有剂量和标志位（添加多巴胺特殊逻辑）
    CROSS JOIN LATERAL (
        SELECT
            -- 1. NE/Epi总碱基剂量计算
            (COALESCE(vaso.rate_norepinephrine, 0) / 2.0 + COALESCE(vaso.rate_epinephrine, 0)) AS ne_epi_total_base_dose,
            -- 2. 多巴胺特殊评分（SOFA2标准：仅当单独使用时）
            CASE
                WHEN COALESCE(vaso.rate_dopamine, 0) > 0
                     AND COALESCE(vaso.rate_epinephrine, 0) = 0
                     AND COALESCE(vaso.rate_norepinephrine, 0) = 0
                     AND COALESCE(vaso.rate_dobutamine, 0) = 0
                     AND COALESCE(vaso.rate_vasopressin, 0) = 0
                     AND COALESCE(vaso.rate_phenylephrine, 0) = 0
                     AND COALESCE(vaso.rate_milrinone, 0) = 0
                THEN
                    CASE
                        WHEN COALESCE(vaso.rate_dopamine, 0) > 40 THEN 4
                        WHEN COALESCE(vaso.rate_dopamine, 0) > 20 THEN 3
                        WHEN COALESCE(vaso.rate_dopamine, 0) > 0 THEN 2
                        ELSE 0
                    END
                ELSE 0
            END AS dopamine_only_score,
            -- 3. 其他血管活性药物标志位（不包括多巴胺单独使用）
            CASE WHEN (COALESCE(vaso.rate_dobutamine, 0) > 0
                      OR COALESCE(vaso.rate_vasopressin, 0) > 0
                      OR COALESCE(vaso.rate_phenylephrine, 0) > 0
                      OR COALESCE(vaso.rate_milrinone, 0) > 0)
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
    WHERE enz.bilirubin_total IS NOT NULL
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
    WHERE chem.creatinine IS NOT NULL
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
    WHERE bg.specimen = 'ART.'
),

-- Step 1: 计算每小时尿量(ml/kg/hr) - 使用urine_output_rate表（SOFA1方法，完整体重数据）
urine_output_hourly_rate AS (
    SELECT
        uo.stay_id,
        FLOOR(EXTRACT(EPOCH FROM (uo.charttime - icu.intime))/3600) AS hr,
        -- 直接使用表中已计算的ml/kg/hr值，权重数据已完整处理
        uo.uo_mlkghr_24hr as uo_ml_kg_hr
    FROM mimiciv_derived.urine_output_rate uo
    LEFT JOIN mimiciv_icu.icustays icu ON uo.stay_id = icu.stay_id
    WHERE uo.uo_mlkghr_24hr IS NOT NULL
),

-- Step 2: 使用 "Gaps and Islands" 算法计算连续低尿量时间 (修复累计vs连续错误)
urine_output_islands AS (
    SELECT
        stay_id,
        hr,
        -- 为每个条件创建连续小时组
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, is_low_05 ORDER BY hr) as island_low_05,
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, is_low_03 ORDER BY hr) as island_low_03,
        hr - ROW_NUMBER() OVER (PARTITION BY stay_id, is_anuric ORDER BY hr) as island_anuric,
        is_low_05, is_low_03, is_anuric
    FROM (
        SELECT
            stay_id, hr,
            -- 各条件标志
            CASE WHEN uo_ml_kg_hr < 0.5 THEN 1 ELSE 0 END as is_low_05,
            CASE WHEN uo_ml_kg_hr < 0.3 THEN 1 ELSE 0 END as is_low_03,
            CASE WHEN uo_ml_kg_hr = 0 THEN 1 ELSE 0 END as is_anuric
        FROM urine_output_hourly_rate
    ) flagged
),
urine_output_durations AS (
    SELECT
        stay_id,
        hr,
        -- 计算每种条件下的连续时长
        CASE WHEN is_low_05 = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_low_05, island_low_05) ELSE 0 END as consecutive_low_05h,
        CASE WHEN is_low_03 = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_low_03, island_low_03) ELSE 0 END as consecutive_low_03h,
        CASE WHEN is_anuric = 1 THEN COUNT(*) OVER (PARTITION BY stay_id, is_anuric, island_anuric) ELSE 0 END as consecutive_anuric_h
    FROM urine_output_islands
),

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
        MAX(uo.consecutive_low_05h) AS consecutive_low_05h_max,
        MAX(uo.consecutive_low_03h) AS consecutive_low_03h_max,
        MAX(uo.consecutive_anuric_h) AS consecutive_anuric_h_max,
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
    LEFT JOIN urine_output_durations uo ON co.stay_id = uo.stay_id AND co.hr = uo.hr
    GROUP BY co.stay_id, co.hr
),
kidney AS (
    SELECT
        stay_id,
        hr,
        GREATEST(
            CASE WHEN rrt_active_flag = 1 THEN 4 ELSE 0 END,
            CASE
                WHEN (creatinine_max > 1.2 OR consecutive_low_03h_max >= 6)
                     AND (COALESCE(potassium_max, 0) >= 6.0
                          OR (COALESCE(ph_min, 7.4) <= 7.2 AND COALESCE(bicarbonate_min, 24) <= 12))
                THEN 4 ELSE 0 END,
            CASE
                WHEN creatinine_max > 3.5 THEN 3
                WHEN creatinine_max > 2.0 THEN 2
                WHEN creatinine_max > 1.2 THEN 1
                ELSE 0 END,
            CASE
                WHEN consecutive_low_03h_max >= 24 THEN 3
                WHEN consecutive_anuric_h_max >= 12 THEN 3
                WHEN consecutive_low_05h_max >= 12 THEN 2
                WHEN consecutive_low_05h_max >= 6 THEN 1
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
    WHERE cbc.platelet IS NOT NULL
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
-- 最终输出
-- =================================================================
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
WHERE hr >= 0
ORDER BY stay_id, hr;
