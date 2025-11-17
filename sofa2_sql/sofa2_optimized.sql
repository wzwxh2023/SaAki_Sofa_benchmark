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
    WHERE ih.hr BETWEEN 0 AND 24
        -- 限制样本用于测试，可移除此限制
        AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 100)
),

-- =================================================================
-- 预处理步骤 (Staging CTEs)
-- =================================================================

-- 步骤1: 预处理药物列表（统一维护，避免重复）
, drug_params AS (
    SELECT
        -- 镇静/镇痛药物（ICU常用镇静药物）
        ARRAY['%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
              '%fentanyl%', '%remifentanil%', '%morphine%', '%hydromorphone%',
              '%dexmedetomidine%', '%ketamine%', '%clonidine%', '%etomidate%'] AS sedation_patterns,
        -- 谌妄药物（抗精神病药物用于谵妄控制）
        ARRAY['%haloperidol%', '%haldol%', '%quetiapine%', '%seroquel%',
              '%olanzapine%', '%zyprexa%', '%risperidone%', '%risperdal%',
              '%ziprasidone%', '%geodon%', '%clozapine%', '%aripiprazole%'] AS delirium_patterns
),

-- 步骤2: 预处理所有GCS测量值，包括数据清洗和镇静状态标记
, gcs_stg AS (
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
        MAX(CASE
            WHEN pr.starttime <= gcs.charttime
                 AND COALESCE(pr.stoptime, gcs.charttime + INTERVAL '1 minute') > gcs.charttime
                 AND LOWER(pr.drug) ILIKE ANY (SELECT sedation_patterns FROM drug_params)
            THEN 1 ELSE 0
        END) AS is_sedated
    FROM mimiciv_derived.gcs gcs
    -- 提前与icustays和prescriptions连接，避免LATERAL中重复连接
    INNER JOIN mimiciv_icu.icustays ie ON gcs.stay_id = ie.stay_id
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE gcs.gcs IS NOT NULL
    GROUP BY gcs.stay_id, gcs.charttime, gcs.gcs
),

-- 步骤3: 预处理每小时的谵妄药物使用情况
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
-- BRAIN/神经系统 (整合版本：性能优化 + 逻辑清晰)
-- =================================================================
, gcs AS (
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
, pf_ratios_all AS (
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
    WHERE bg.specimen = 'ART.'
      AND bg.pao2fio2ratio IS NOT NULL
      AND bg.pao2fio2ratio > 0
),

-- 步骤2: 预计算SpO2和FiO2的原始数据
, spo2_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        ce.valuenum AS spo2_value
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 220277  -- SpO2
      AND ce.valuenum > 0
      AND ce.valuenum < 98  -- SF ratio只在SpO2<98%时有效
),

, fio2_raw AS (
    SELECT
        ce.stay_id,
        ce.charttime,
        ce.valuenum AS fio2_value  -- FiO2百分比 (21-100%)
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 223835  -- 正确的FiO2 itemid
      AND ce.valuenum BETWEEN 21 AND 100  -- FiO2百分比范围
),

-- 步骤3: 预计算所有SF比值 (SpO2:FiO2)
, sf_ratios_all AS (
    SELECT
        spo2.stay_id,
        spo2.charttime,
        (spo2.spo2_value / (fio2.fio2_value / 100.0)) AS oxygen_ratio,  -- 关键修复：百分比转小数
        adv.advanced_support AS has_advanced_support
    FROM spo2_raw spo2
    INNER JOIN fio2_raw fio2
        ON spo2.stay_id = fio2.stay_id
        AND spo2.charttime >= fio2.charttime
        AND spo2.charttime < fio2.charttime + INTERVAL '1 hour'
    LEFT JOIN LATERAL (
        SELECT
            CASE WHEN EXISTS(
                SELECT 1 FROM mimiciv_derived.ventilation vd
                WHERE vd.stay_id = spo2.stay_id
                  AND vd.starttime < spo2.charttime + INTERVAL '1 hour'
                  AND COALESCE(vd.endtime, spo2.charttime + INTERVAL '1 hour') > spo2.charttime
                  AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC')
            ) THEN 1 ELSE 0 END AS advanced_support
    ) adv ON TRUE
    WHERE spo2.spo2_value IS NOT NULL
      AND fio2.fio2_value IS NOT NULL
),

-- 步骤4: 预计算所有ECMO记录
, ecmo_events AS (
    -- 方法1: 机械支持表中的ECMO
    SELECT
        ce.stay_id,
        ce.charttime,
        1 AS ecmo_indicator
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid = 224660  -- 机械支持表ECMO

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
, pf_hourly AS (
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
, sf_hourly AS (
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
, respiratory_hourly AS (
    SELECT
        co.stay_id,
        co.hr,

        -- ECMO状态：小时内是否有ECMO
        COALESCE(MAX(ecmo.ecmo_indicator), 0) AS on_ecmo,

        -- 氧合指数类型：严格PF优先
        CASE
            WHEN pf.pf_ratio_min IS NOT NULL THEN 'PF'
            WHEN sf.sf_ratio_min IS NOT NULL THEN 'SF'
            ELSE NULL
        END AS ratio_type,

        -- 氧合指数值：严格对应的PF或SF值
        COALESCE(pf.pf_ratio_min, sf.sf_ratio_min) AS oxygen_ratio,

        -- 呼吸支持状态：必须与氧合指数类型匹配！
        CASE
            WHEN pf.pf_ratio_min IS NOT NULL THEN pf.pf_has_support  -- PF对应的支持状态
            WHEN sf.sf_ratio_min IS NOT NULL THEN sf.sf_has_support  -- SF对应的支持状态
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
),

-- =================================================================
-- RESPIRATORY/呼吸系统 (SOFA2标准：最终评分计算)
-- =================================================================
, respiratory AS (
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
-- CARDIOVASCULAR/心血管 (SOFA2标准：血管活性药物分级)
-- =================================================================
, cardiovascular AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- 4分: 高剂量血管升压药或机械循环支持
            WHEN coalesce(rate_norepinephrine, 0) + coalesce(rate_epinephrine, 0) > 0.4 THEN 4
            WHEN mech.has_mechanical_support = 1 THEN 4
            -- 3分: 中剂量血管升压药
            WHEN coalesce(rate_norepinephrine, 0) + coalesce(rate_epinephrine, 0) > 0.2 THEN 3
            -- 2分: 低剂量血管升压药或其他升压药
            WHEN coalesce(rate_norepinephrine, 0) + coalesce(rate_epinephrine, 0) > 0 THEN 2
            WHEN coalesce(rate_dobutamine, 0) > 0 OR coalesce(rate_dopamine, 0) > 0
                 OR coalesce(rate_vasopressin, 0) > 0 THEN 2
            -- 1分: MAP < 70 无血管活性药
            WHEN mbp_min < 70 AND coalesce(rate_norepinephrine, 0) = 0
                 AND coalesce(rate_epinephrine, 0) = 0 THEN 1
            -- 0分: 正常
            ELSE 0
        END AS cardiovascular
    FROM co
    LEFT JOIN LATERAL (
        SELECT MIN(vs.mbp) as mbp_min
        FROM mimiciv_derived.vitalsign vs
        WHERE vs.stay_id = co.stay_id
            AND vs.charttime >= co.starttime
            AND vs.charttime < co.endtime
    ) vit ON TRUE
    LEFT JOIN LATERAL (
        SELECT
            MAX(norepinephrine) as rate_norepinephrine,
            MAX(epinephrine) as rate_epinephrine,
            MAX(dopamine) as rate_dopamine,
            MAX(dobutamine) as rate_dobutamine,
            MAX(vasopressin) as rate_vasopressin
        FROM mimiciv_derived.vasoactive_agent va
        WHERE va.stay_id = co.stay_id
            AND va.starttime < co.endtime
            AND COALESCE(va.endtime, co.endtime) > co.starttime
    ) vaso ON TRUE
    LEFT JOIN LATERAL (
        SELECT MAX(CASE WHEN ce.itemid = 224660 THEN 1 ELSE 0 END) as has_mechanical_support
        FROM mimiciv_icu.chartevents ce
        WHERE ce.stay_id = co.stay_id
            AND ce.charttime >= co.starttime
            AND ce.charttime < co.endtime
    ) mech ON TRUE
),

-- =================================================================
-- LIVER/肝脏 (SOFA2标准：胆红素阈值调整)
-- =================================================================
, liver AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN enz.bilirubin_max > 12.0 THEN 4
            WHEN enz.bilirubin_max > 6.0 AND enz.bilirubin_max <= 12.0 THEN 3
            WHEN enz.bilirubin_max > 3.0 AND enz.bilirubin_max <= 6.0 THEN 2
            WHEN enz.bilirubin_max > 1.2 AND enz.bilirubin_max <= 3.0 THEN 1
            WHEN enz.bilirubin_max IS NULL THEN NULL
            ELSE 0
        END AS liver
    FROM co
    LEFT JOIN LATERAL (
        SELECT MAX(enz.bilirubin_total) as bilirubin_max
        FROM mimiciv_derived.enzyme enz
        WHERE enz.hadm_id IN (SELECT hadm_id FROM mimiciv_icu.icustays WHERE stay_id = co.stay_id)
            AND enz.charttime >= co.starttime
            AND enz.charttime < co.endtime
    ) enz ON TRUE
),

-- =================================================================
-- KIDNEY/肾脏 (SOFA2标准：连续尿量 + RRT标准)
-- =================================================================
, kidney AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- 4分: RRT或符合RRT标准
            WHEN rrt.on_rrt = 1 THEN 4
            WHEN (
                (chem.creatinine_max > 1.2 OR uo.low_03_hours >= 6)
                AND (
                    bg.k_max >= 6.0
                    OR (bg.ph_min <= 7.2 AND bg.bicarbonate_min <= 12)
                )
            ) THEN 4
            -- 3分: 肌酐 >3.5 或严重少尿
            WHEN chem.creatinine_max > 3.5 THEN 3
            WHEN uo.low_03_hours >= 24 THEN 3
            WHEN uo.anuria_hours >= 12 THEN 3
            -- 2分: 肌酐 2.0-3.5 或中度少尿
            WHEN chem.creatinine_max > 2.0 THEN 2
            WHEN uo.low_05_hours >= 12 THEN 2
            -- 1分: 肌酐 1.2-2.0 或轻度少尿
            WHEN chem.creatinine_max > 1.2 THEN 1
            WHEN uo.low_05_hours >= 6 AND uo.low_05_hours < 12 THEN 1
            -- 0分: 正常
            ELSE 0
        END AS kidney
    FROM co
    LEFT JOIN LATERAL (
        SELECT MAX(chem.creatinine) as creatinine_max
        FROM mimiciv_derived.chemistry chem
        WHERE chem.hadm_id IN (SELECT hadm_id FROM mimiciv_icu.icustays WHERE stay_id = co.stay_id)
            AND chem.charttime >= co.starttime
            AND chem.charttime < co.endtime
    ) chem ON TRUE
    LEFT JOIN LATERAL (
        SELECT MAX(bg.ph) as ph_min, MAX(bg.potassium) as k_max, MIN(bg.bicarbonate) as bicarbonate_min
        FROM mimiciv_derived.bg bg
        WHERE bg.subject_id IN (SELECT subject_id FROM mimiciv_icu.icustays WHERE stay_id = co.stay_id)
            AND bg.specimen = 'ART.'
            AND bg.charttime >= co.starttime
            AND bg.charttime < co.endtime
    ) bg ON TRUE
    LEFT JOIN LATERAL (
        -- 简化尿量计算
        SELECT
            CASE WHEN uo.urineoutput / 70 / 1 < 0.5 THEN 1 ELSE 0 END as low_05_hours,
            CASE WHEN uo.urineoutput / 70 / 1 < 0.3 THEN 1 ELSE 0 END as low_03_hours,
            CASE WHEN uo.urineoutput = 0 THEN 1 ELSE 0 END as anuria_hours
        FROM (
            SELECT COALESCE(SUM(uo.urineoutput), 0) as urineoutput
            FROM mimiciv_derived.urine_output uo
            WHERE uo.stay_id = co.stay_id
                AND uo.charttime >= co.starttime
                AND uo.charttime < co.endtime
        ) uo
    ) uo ON TRUE
    LEFT JOIN LATERAL (
        SELECT MAX(rrt.dialysis_active) as on_rrt
        FROM mimiciv_derived.rrt rrt
        WHERE rrt.stay_id = co.stay_id
            AND rrt.charttime <= co.endtime
        ORDER BY rrt.charttime DESC
        LIMIT 1
    ) rrt ON TRUE
),

-- =================================================================
-- HEMOSTASIS/凝血 (SOFA2标准：血小板计数)
-- =================================================================
, hemostasis AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            WHEN cbc.platelet_min <= 50 THEN 4
            WHEN cbc.platelet_min <= 80 THEN 3
            WHEN cbc.platelet_min <= 100 THEN 2
            WHEN cbc.platelet_min <= 150 THEN 1
            WHEN cbc.platelet_min IS NULL THEN NULL
            ELSE 0
        END AS hemostasis
    FROM co
    LEFT JOIN LATERAL (
        SELECT MIN(cbc.platelet) as platelet_min
        FROM mimiciv_derived.complete_blood_count cbc
        WHERE cbc.hadm_id IN (SELECT hadm_id FROM mimiciv_icu.icustays WHERE stay_id = co.stay_id)
            AND cbc.charttime >= co.starttime
            AND cbc.charttime < co.endtime
    ) cbc ON TRUE
),

-- =================================================================
-- 综合评分 (参考SOFA1的窗口函数实现)
-- =================================================================
, score_final AS (
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