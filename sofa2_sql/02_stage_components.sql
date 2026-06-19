-- =================================================================
-- 步骤 2: 生成各组件中间表 (UNLOGGED Tables)
-- =================================================================
-- =================================================================
-- 2.1 镇静药物 (Sedation)
-- 数据源: mimiciv_icu.inputevents (精准输注记录)
-- 逻辑:
-- 1. 包含核心镇静剂及巴比妥类 (脑保护/深镇静)
-- 2. 排除纯阿片类镇痛药 (如芬太尼) 以防掩盖真实神经恶化
-- 3. 增加 1小时 Washout Buffer (停药后1小时内仍视为镇静影响)
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_sedation CASCADE;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_sedation AS
SELECT 
    stay_id,
    starttime,
    endtime
FROM mimiciv_icu.inputevents
WHERE itemid IN (
    -- === 核心镇静剂 ===
    222168, -- Propofol (丙泊酚)
    221668, -- Midazolam (咪达唑仑)
    229420, -- Dexmedetomidine (右美托咪定 - 主要ID)
    225150, -- Dexmedetomidine (右美托咪定 - 次要ID)
    221385, -- Lorazepam (劳拉西泮)
    221712, -- Ketamine (氯胺酮)
    221756, -- Etomidate (依托咪酯)

    -- === 巴比妥类 (深度昏迷诱导) ===
    225156  -- Pentobarbital (戊巴比妥)
)
AND amount > 0; -- 确保有实际给药

CREATE INDEX idx_st1_sedation ON mimiciv_derived.sofa2_stage1_sedation(stay_id, starttime, endtime);


-- =================================================================
-- 2.2 谵妄药物 (Delirium Meds)
-- 数据源: mimiciv_hosp.prescriptions (医嘱)
-- 逻辑: 模糊匹配常见抗精神病药物，映射到小时网格
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_delirium CASCADE;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_delirium AS
SELECT 
    ih.stay_id, 
    ih.hr, 
    MAX(1) AS on_delirium_med
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
WHERE (
    -- 1. 氟哌啶醇
    pr.drug ILIKE '%haloperidol%' 
    
    -- 2. 喹硫平 (含 Seroquel)
    OR pr.drug ILIKE '%quetiapine%' OR pr.drug ILIKE '%seroquel%'
    
    -- 3. 奥氮平 (含 Zyprexa)
    OR pr.drug ILIKE '%olanzapine%' OR pr.drug ILIKE '%zyprexa%'
    
    -- 4. 利培酮 (含 Risperdal)
    OR pr.drug ILIKE '%risperidone%' OR pr.drug ILIKE '%risperdal%'
    
    -- 5. 齐拉西酮 (含 Geodon)
    OR pr.drug ILIKE '%ziprasidone%' OR pr.drug ILIKE '%geodon%'
    
    -- 6. 氯氮平
    OR pr.drug ILIKE '%clozapine%'
    
    -- 7. 阿立哌唑 (含 Abilify)
    OR pr.drug ILIKE '%aripiprazole%' OR pr.drug ILIKE '%abilify%'
)
-- 排除外用制剂
AND pr.drug NOT ILIKE '%TOPICAL%'
-- 时间窗口匹配
AND pr.starttime <= ih.endtime
AND COALESCE(pr.stoptime, pr.starttime + INTERVAL '24 hours') >= ih.endtime - INTERVAL '1 HOUR'
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_delirium ON mimiciv_derived.sofa2_stage1_delirium(stay_id, hr);


-- =================================================================
-- 2.3 神经系统 GCS (Brain) - 核心评分表
-- 逻辑: 
-- 1. 修正插管误判 (gcs_unable=1 时强制用 Motor)
-- 2. 评分优先级: Total GCS > Motor GCS
-- 3. 镇静回溯 (LOCF): 镇静时沿用最近一次清醒分
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_brain CASCADE;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_brain AS

-- A. 计算单次记录的 Raw SOFA Score
WITH gcs_base AS (
    SELECT 
        g.stay_id, 
        g.charttime, 
        
        CASE 
            -- 场景 A: 插管状态 (unable=1) -> 强制用 Motor
            WHEN g.gcs_unable = 1 THEN 
                CASE 
                    WHEN g.gcs_motor <= 2 THEN 4
                    WHEN g.gcs_motor = 3 THEN 3
                    WHEN g.gcs_motor = 4 THEN 2
                    WHEN g.gcs_motor = 5 THEN 1
                    WHEN g.gcs_motor = 6 THEN 0
                    ELSE NULL 
                END
            
            -- 场景 B: 非插管 -> 优先 Total, 兜底 Motor
            ELSE COALESCE(
                -- Total GCS 映射
                CASE 
                    WHEN g.gcs <= 5 THEN 4
                    WHEN g.gcs <= 8 THEN 3
                    WHEN g.gcs <= 12 THEN 2
                    WHEN g.gcs <= 14 THEN 1
                    WHEN g.gcs = 15 THEN 0
                    ELSE NULL 
                END,
                -- Motor GCS 映射
                CASE 
                    WHEN g.gcs_motor <= 2 THEN 4
                    WHEN g.gcs_motor = 3 THEN 3
                    WHEN g.gcs_motor = 4 THEN 2
                    WHEN g.gcs_motor = 5 THEN 1
                    WHEN g.gcs_motor = 6 THEN 0
                    ELSE NULL 
                END
            )
        END AS brain_score_raw,
        
        -- 标记是否镇静 (关联上面生成的 2.1 表)
        CASE WHEN s.stay_id IS NOT NULL THEN 1 ELSE 0 END AS is_sedated

    FROM mimiciv_derived.gcs g
    LEFT JOIN mimiciv_derived.sofa2_stage1_sedation s 
      ON g.stay_id = s.stay_id 
      AND g.charttime >= s.starttime 
      AND g.charttime <= s.endtime
),

-- B. 准备 LOCF 分组 (仅未镇静时产生有效值)
gcs_grouping AS (
    SELECT 
        stay_id, 
        charttime, 
        is_sedated,
        CASE WHEN is_sedated = 0 THEN brain_score_raw ELSE NULL END AS valid_score,
        -- 分组计数: 遇到未镇静记录时 +1
        COUNT(CASE WHEN is_sedated = 0 THEN 1 END) 
            OVER (PARTITION BY stay_id ORDER BY charttime) as grp
    FROM gcs_base
),

-- C. 执行回溯
gcs_resolved AS (
    SELECT 
        stay_id, 
        charttime,
        -- 取当前组内的第一个有效值 (实现回溯)
        FIRST_VALUE(valid_score) OVER (
            PARTITION BY stay_id, grp ORDER BY charttime
        ) AS effective_score
    FROM gcs_grouping
)

-- D. 生成最终区间表
SELECT 
    stay_id, 
    charttime AS starttime,
    LEAD(charttime, 1, 'infinity'::timestamp) OVER (PARTITION BY stay_id ORDER BY charttime) AS endtime,
    -- 默认值: 若无历史记录(刚入科即镇静)，默认为 0
    COALESCE(effective_score, 0) AS brain_score_final
FROM gcs_resolved;

CREATE INDEX idx_st1_brain ON mimiciv_derived.sofa2_stage1_brain(stay_id, starttime, endtime);
-- =================================================================
-- =================================================================
-- Step 2: 呼吸系统组件预处理 (Respiratory Staging)
-- 包含: 呼吸支持状态、机械循环支持(ECMO)、氧合指数
-- =================================================================

-- -----------------------------------------------------------------
-- 2.4 呼吸支持状态 (Respiratory Support)
-- 来源: mimiciv_derived.ventilation
-- 逻辑: 包含 HFNC, NIV, Invasive, Trach (满足 SOFA 3-4分条件)
-- -----------------------------------------------------------------
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_resp_support;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_resp_support AS
SELECT 
    ih.stay_id,
    ih.hr,
    MAX(1) AS with_resp_support
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
JOIN mimiciv_derived.ventilation v 
    ON ih.stay_id = v.stay_id
WHERE
    -- 时间重叠判断
    ih.endtime > v.starttime
    AND ih.endtime - INTERVAL '1 HOUR' < v.endtime
    -- 必须属于高级支持类型
    AND v.ventilation_status IN (
        'InvasiveVent', 
        'NonInvasiveVent', 
        'Tracheostomy', 
        'HFNC'
    )
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_resp_sup 
ON mimiciv_derived.sofa2_stage1_resp_support(stay_id, hr);

-- -----------------------------------------------------------------
-- 2.5 机械循环支持 (Mech Support / ECMO) - 增强版：区分VV/VA-ECMO
-- 根据 itemid=229268 (Circuit Configuration) 区分ECMO类型
-- 数据分布: VV=17950, VA=9926, ---=290, VAV=41
-- -----------------------------------------------------------------
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_mech;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_mech AS
SELECT 
    ih.stay_id, 
    ih.hr,
    
    -- 1. 检测是否有ECMO（任何类型）
    MAX(CASE WHEN ce.itemid IN (
        224660, 229270, 229277, 229280, 229278, 229363, 229364, 229365, 228193
    ) THEN 1 ELSE 0 END) AS is_ecmo,
    
    -- 2. VV-ECMO
    MAX(CASE WHEN ce.itemid = 229268 AND ce.value = 'VV'
         THEN 1 ELSE 0 END) AS is_vv_ecmo,
    
    -- 3. VA/VAV-ECMO
    MAX(CASE WHEN ce.itemid = 229268 AND ce.value IN ('VA', 'VAV')
         THEN 1 ELSE 0 END) AS is_va_ecmo,
    
    -- 4. ECMO类型未知
    MAX(CASE WHEN ce.itemid = 229268 AND (ce.value = '---' OR ce.value IS NULL OR ce.value = '')
         THEN 1 ELSE 0 END) AS is_ecmo_unknown_type,
    
    -- 5. 其他机械支持
    MAX(CASE WHEN ce.itemid IN (
        224322, 227980, 225980, 228866,
        228154, 229671, 229897, 229898, 229899, 229900,
        220125, 220128, 229254, 229262, 229255, 229263
    ) THEN 1 ELSE 0 END) AS is_other_mech

FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
LEFT JOIN mimiciv_icu.chartevents ce           -- ✅ 改为 LEFT JOIN
    ON ih.stay_id = ce.stay_id
    AND ce.charttime >= ih.endtime - INTERVAL '1 HOUR' 
    AND ce.charttime <= ih.endtime
    AND ce.itemid IN (                          -- ✅ 条件移到ON子句
        224660, 229270, 229277, 229280, 229278, 229363, 229364, 229365, 228193,
        229268,
        224322, 227980, 225980, 228866,
        228154, 229671, 229897, 229898, 229899, 229900,
        220125, 220128, 229254, 229262, 229255, 229263
    )
GROUP BY ih.stay_id, ih.hr;                     -- ✅ 移除WHERE子句

CREATE INDEX idx_st1_mech ON mimiciv_derived.sofa2_stage1_mech(stay_id, hr);

-- 2.6 氧合指数 (Oxygenation)
-- 逻辑: 1小时窗口精确匹配
-- -----------------------------------------------------------------
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_oxygen;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_oxygen AS

-- A. FiO2: 整合 Chartevents 和 BloodGas（优先级处理）
WITH fio2_raw AS (
    SELECT stay_id, charttime, fio2, source,
           ROW_NUMBER() OVER (
               PARTITION BY stay_id, charttime 
               ORDER BY priority
           ) as rn
    FROM (
        -- 血气来源：优先级1（更准确）
        SELECT ie.stay_id, bg.charttime, bg.fio2, 'bg' as source, 1 as priority
        FROM mimiciv_derived.bg bg
        JOIN mimiciv_icu.icustays ie 
            ON bg.hadm_id = ie.hadm_id
            AND bg.charttime >= ie.intime 
            AND bg.charttime <= ie.outtime
        WHERE bg.fio2 IS NOT NULL
        
        UNION ALL
        
        -- Chartevents来源：优先级2
        SELECT stay_id, charttime, valuenum AS fio2, 'ce' as source, 2 as priority
        FROM mimiciv_icu.chartevents 
        WHERE itemid = 223835 AND valuenum > 0
    ) x
),
fio2_all AS (
    SELECT stay_id, charttime, fio2
    FROM fio2_raw
    WHERE rn = 1
),

-- B. SpO2: 仅 Chartevents
spo2_all AS (
    SELECT stay_id, charttime, valuenum AS spo2 
    FROM mimiciv_icu.chartevents 
    WHERE itemid = 220277 AND valuenum > 0 AND valuenum <= 100
),

-- C. PaO2: 仅动脉血气（需要JOIN获取stay_id）
pao2_all AS (
    SELECT ie.stay_id, bg.charttime, bg.po2 AS pao2 
    FROM mimiciv_derived.bg bg
    JOIN mimiciv_icu.icustays ie 
        ON bg.hadm_id = ie.hadm_id
        AND bg.charttime >= ie.intime 
        AND bg.charttime <= ie.outtime
    WHERE bg.specimen = 'ART.' AND bg.po2 IS NOT NULL
)

SELECT 
    ih.stay_id,
    ih.hr,
    
    -- 1. 计算 PF Ratio
    (
        (ARRAY_AGG(p.pao2 ORDER BY p.charttime DESC))[1] 
        / 
        NULLIF(COALESCE(
            (ARRAY_AGG(f.fio2 ORDER BY f.charttime DESC))[1], 
            21
        ), 0)
        * 100
    ) AS pf_ratio,

    -- 2. 计算 SF Ratio
    (
        (ARRAY_AGG(s.spo2 ORDER BY s.charttime DESC))[1] 
        / 
        NULLIF(COALESCE(
            (ARRAY_AGG(f.fio2 ORDER BY f.charttime DESC))[1], 
            21
        ), 0)
        * 100
    ) AS sf_ratio,
    
    -- 3. 原始 SpO2 (用于 Step 3 过滤 <98%)
    (ARRAY_AGG(s.spo2 ORDER BY s.charttime DESC))[1] AS raw_spo2

FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
LEFT JOIN pao2_all p 
    ON ih.stay_id = p.stay_id 
    AND p.charttime > ih.endtime - INTERVAL '1 HOUR' 
    AND p.charttime <= ih.endtime
LEFT JOIN spo2_all s 
    ON ih.stay_id = s.stay_id 
    AND s.charttime > ih.endtime - INTERVAL '1 HOUR' 
    AND s.charttime <= ih.endtime
LEFT JOIN fio2_all f 
    ON ih.stay_id = f.stay_id 
    AND f.charttime > ih.endtime - INTERVAL '1 HOUR' 
    AND f.charttime <= ih.endtime
WHERE ih.hr >= -24
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_oxy ON mimiciv_derived.sofa2_stage1_oxygen(stay_id, hr);

-- =================================================================
-- 2.9 肾脏 Lab (Kidney Labs)
-- 优化: 直接生成小时级 Lab 数据，向前回溯 6 小时取极值
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_kidney_labs;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_kidney_labs AS
SELECT
    ih.stay_id,
    ih.hr,
    MAX(chem.creatinine) AS creatinine,
    GREATEST(MAX(chem.potassium), MAX(bg.potassium)) AS potassium,
    MIN(bg.ph) AS ph,
    LEAST(MIN(chem.bicarbonate), MIN(bg.bicarbonate)) AS bicarbonate
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
LEFT JOIN mimiciv_derived.chemistry chem
    ON ie.hadm_id = chem.hadm_id                          -- [P2] subject_id → hadm_id，限制在当前住院
    AND chem.charttime > ih.endtime - INTERVAL '1 HOUR'
    AND chem.charttime <= ih.endtime
LEFT JOIN mimiciv_derived.bg bg
    ON ie.hadm_id = bg.hadm_id                            -- [P2] subject_id → hadm_id，限制在当前住院
    AND bg.charttime > ih.endtime - INTERVAL '1 HOUR'
    AND bg.charttime <= ih.endtime
WHERE ih.hr >= -24
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_klabs ON mimiciv_derived.sofa2_stage1_kidney_labs(stay_id, hr);


-- =================================================================
-- 2.10 RRT 状态 (Hourly RRT Status)
-- 优化: 改为小时级状态，包含腹透判定 (present OR active)
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_rrt;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_rrt AS
SELECT 
    ih.stay_id,
    ih.hr,
    -- 只要 dialysis_present=1 (在周期内) 或 active=1 (正在透) 都算 RRT
    MAX(CASE WHEN rrt.dialysis_present = 1 OR rrt.dialysis_active = 1 THEN 1 ELSE 0 END) AS on_rrt
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
LEFT JOIN mimiciv_derived.rrt rrt 
    ON ih.stay_id = rrt.stay_id
    AND rrt.charttime >= ih.endtime - INTERVAL '1 HOUR'
    AND rrt.charttime <= ih.endtime
WHERE ih.hr >= -24
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_rrt ON mimiciv_derived.sofa2_stage1_rrt(stay_id, hr);


-- =================================================================
-- 2.11 尿量速率 (Urine Output Rate)
-- Source: official MIMIC derived table mimiciv_derived.urine_output_rate.
-- Rationale: do not rebuild urine-output rates from sparse raw events on a
-- fixed ICU hourly grid. The official derived table carries observed-time
-- denominators (uo_tm_6hr/12hr/24hr) and normalized rates.
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_urine;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_urine AS
SELECT
    ih.stay_id,
    ih.hr,
    MIN(uor.weight) AS weight,
    MIN(uor.urineoutput_6hr) AS urineoutput_6hr,
    MIN(uor.urineoutput_12hr) AS urineoutput_12hr,
    MIN(uor.urineoutput_24hr) AS urineoutput_24hr,
    MIN(uor.uo_tm_6hr) AS uo_tm_6hr_min,
    MIN(uor.uo_tm_12hr) AS uo_tm_12hr_min,
    MIN(uor.uo_tm_24hr) AS uo_tm_24hr_min,
    -- If multiple urine_output_rate rows fall in one ICU hour, keep the worst
    -- observed rolling rate. This follows SOFA's worst-value scoring convention.
    MIN(uor.uo_mlkghr_6hr) AS uo_mlkghr_6hr_min,
    MIN(uor.uo_mlkghr_12hr) AS uo_mlkghr_12hr_min,
    MIN(uor.uo_mlkghr_24hr) AS uo_mlkghr_24hr_min,
    MAX(CASE
        WHEN uor.urineoutput_12hr = 0 AND uor.uo_tm_12hr >= 12 THEN 1
        ELSE 0
    END) AS anuria_12h_official,
    COUNT(uor.charttime) AS uor_events_in_hour
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
LEFT JOIN mimiciv_derived.urine_output_rate uor
    ON ih.stay_id = uor.stay_id
    AND uor.charttime > ih.endtime - INTERVAL '1 HOUR'
    AND uor.charttime <= ih.endtime
WHERE ih.hr >= -24
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_urine ON mimiciv_derived.sofa2_stage1_urine(stay_id, hr);

-- -----------------------------------------------------------------
-- 2.12 凝血系统 (Coagulation)
-- Policy:
--   - strict: current ICU hour only, used as the SOFA-2 definition anchor
--   - lab48: previous 48h, used only later as rescue when the rolling strict
--     24h window has no platelet evidence
-- -----------------------------------------------------------------
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_coag;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_coag AS

WITH plt_raw AS (
    SELECT hadm_id, charttime, platelet 
    FROM mimiciv_derived.complete_blood_count 
    WHERE platelet IS NOT NULL
)

SELECT 
    ih.stay_id, 
    ih.hr,
    MIN(p.platelet) FILTER (
        WHERE p.charttime > ih.endtime - INTERVAL '1 HOUR'
          AND p.charttime <= ih.endtime
    ) AS platelet_min_strict,
    MIN(p.platelet) AS platelet_min_lab48
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
LEFT JOIN plt_raw p 
    ON ie.hadm_id = p.hadm_id
    AND p.charttime > ih.endtime - INTERVAL '48 HOUR' 
    AND p.charttime <= ih.endtime
WHERE ih.hr >= -24
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_coag ON mimiciv_derived.sofa2_stage1_coag(stay_id, hr);


-- -----------------------------------------------------------------
-- 2.13 肝脏系统 (Liver)
-- 数据源: mimiciv_derived.enzyme (确认包含 bilirubin_total)
-- Policy:
--   - strict: current ICU hour only, used as the SOFA-2 definition anchor
--   - lab48: previous 48h, used only later as rescue when the rolling strict
--     24h window has no bilirubin evidence
-- -----------------------------------------------------------------
DROP TABLE IF EXISTS mimiciv_derived.sofa2_stage1_liver;
CREATE UNLOGGED TABLE mimiciv_derived.sofa2_stage1_liver AS

WITH bili_raw AS (
    SELECT hadm_id, charttime, bilirubin_total 
    FROM mimiciv_derived.enzyme 
    WHERE bilirubin_total IS NOT NULL
)

SELECT 
    ih.stay_id, 
    ih.hr,
    MAX(b.bilirubin_total) FILTER (
        WHERE b.charttime > ih.endtime - INTERVAL '1 HOUR'
          AND b.charttime <= ih.endtime
    ) AS bilirubin_max_strict,
    MAX(b.bilirubin_total) AS bilirubin_max_lab48
FROM mimiciv_derived.icustay_hourly_basedon_icuintime ih
JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
LEFT JOIN bili_raw b 
    ON ie.hadm_id = b.hadm_id
    AND b.charttime > ih.endtime - INTERVAL '48 HOUR' 
    AND b.charttime <= ih.endtime
WHERE ih.hr >= -24
GROUP BY ih.stay_id, ih.hr;

CREATE INDEX idx_st1_liver ON mimiciv_derived.sofa2_stage1_liver(stay_id, hr);
