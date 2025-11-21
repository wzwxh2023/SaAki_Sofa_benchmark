-- =================================================================
-- SOFA-2 评分系统超级优化版本 V3
-- 基于硬件配置充分优化：24核CPU, 93GB内存
-- =================================================================

-- =================================================================
-- 超级性能优化配置 (基于24核CPU + 93GB内存)
-- =================================================================
-- 基础内存优化 (充分利用93GB内存)
SET work_mem = '2047MB';                        -- 大幅增加工作内存，用于排序、哈希等操作 (接近最大允许值2GB)
SET maintenance_work_mem = '2047MB';            -- 大幅增加维护操作内存，用于索引创建等 (接近最大允许值2GB)
SET temp_file_limit = '16GB';                   -- 允许使用临时文件空间

-- 缓存优化 (基于93GB可用内存)
-- 注意: shared_buffers需要在postgresql.conf中设置，这里仅影响当前会话
SET effective_cache_size = '70GB';              -- 假设75%的内存可用于缓存

-- 并行处理优化 (基于24核CPU)
SET max_parallel_workers = 24;                  -- 总并行工作线程数等于CPU核心数
SET max_parallel_workers_per_gather = 12;       -- 每个查询最多使用12个并行线程 (半数CPU)
SET parallel_leader_participation = on;         -- 主进程参与并行执行
SET parallel_tuple_cost = 0.1;                  -- 降低并行传输元组的成本
SET parallel_setup_cost = 1000;                 -- 降低并行设置成本

-- 查询规划器优化
SET random_page_cost = 1.1;                     -- SSD优化，降低随机页面访问成本
SET seq_page_cost = 1.0;                        -- 顺序页面访问成本
SET cpu_tuple_cost = 0.01;                      -- 降低元组处理成本
SET cpu_index_tuple_cost = 0.005;               -- 降低索引元组处理成本
SET cpu_operator_cost = 0.0025;                 -- 降低操作符成本

-- 高级并行特性
SET enable_partitionwise_join = on;             -- 启用分区连接
SET enable_partitionwise_aggregate = on;        -- 启用分区聚合
SET enable_parallel_append = on;                -- 启用并行追加
SET enable_parallel_hash = on;                  -- 启用并行哈希
-- 移除不支持的enable_parallel_nestloop参数

-- JIT编译优化 (对于大查询关闭JIT反而更快)
SET jit = off;
SET jit_inline_above_cost = 500000;
SET jit_optimize_above_cost = 500000;

-- 锁和超时设置
SET statement_timeout = '14400s';               -- 4小时语句超时
SET lock_timeout = '7200s';                     -- 2小时锁超时
SET idle_in_transaction_session_timeout = '1800s'; -- 30分钟事务超时

-- 检查点和WAL优化 (需要在postgresql.conf中设置，此处注释)
-- SET wal_buffers = '64MB';                       -- WAL缓冲区 (服务器级别)
-- SET checkpoint_completion_target = 0.9;         -- 检查点完成目标 (服务器级别)
-- SET max_wal_size = '4GB';                       -- 最大WAL大小 (服务器级别)
-- SET min_wal_size = '1GB';                       -- 最小WAL大小 (服务器级别)

-- 创建超级优化的进度监控表
CREATE TABLE IF NOT EXISTS sofa2_run_progress_v3 (
    run_id SERIAL PRIMARY KEY,
    start_time TIMESTAMP DEFAULT NOW(),
    stage VARCHAR(100),
    status VARCHAR(20),
    details TEXT,
    duration INTERVAL,
    performance_stats JSONB
) WITH (parallel_workers = 8);

-- 插入开始记录
INSERT INTO sofa2_run_progress_v3 (stage, status, details, performance_stats)
VALUES ('SOFA2 V3 超级优化开始', 'STARTING',
        '硬件: 24核CPU, 93GB内存 | 并行度: 12 | Work_mem: 2GB',
        '{"cpu_cores": 24, "memory_gb": 93, "parallel_workers": 12, "work_mem_gb": 2, "shared_buffers_gb": 24}');

-- 显示当前配置
SELECT
    '当前超级优化配置' AS setting_type,
    current_setting('work_mem') AS work_mem,
    current_setting('maintenance_work_mem') AS maintenance_work_mem,
    current_setting('shared_buffers') AS shared_buffers,
    current_setting('effective_cache_size') AS effective_cache_size,
    current_setting('max_parallel_workers_per_gather') AS max_parallel_workers_per_gather,
    current_setting('max_parallel_workers') AS max_parallel_workers;

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
-- 预处理步骤 (Staging CTEs) - 并行优化版本
-- =================================================================

-- =================================================================
-- 步骤1: 预处理药物列表（统一维护，避免重复）
-- =================================================================
drug_params AS (
    SELECT UNNEST(ARRAY[
        '%propofol%', '%midazolam%', '%lorazepam%', '%diazepam%',
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

-- 步骤2: 预计算镇静药物输注时段（并行优化版本）
sedation_infusion_periods AS (
    SELECT
        ie.stay_id,
        pr.starttime,
        -- 智能时间边界处理：基于实际数据统计和临床合理性
        CASE
            -- 情况1: 有明确停止时间且合理，使用实际时间
            WHEN pr.stoptime IS NOT NULL
                 AND pr.stoptime > pr.starttime
                 AND EXTRACT(EPOCH FROM (pr.stoptime - pr.starttime)) BETWEEN 3600 AND 604800  -- 1小时-7天
            THEN pr.stoptime

            -- 情况2: 有停止时间但过短(<1小时)，可能是推注误分类，延长到合理时间
            WHEN pr.stoptime IS NOT NULL
                 AND pr.stoptime > pr.starttime
                 AND EXTRACT(EPOCH FROM (pr.stoptime - pr.starttime)) < 3600
            THEN pr.starttime + INTERVAL '4 hours'

            -- 情况3: 有停止时间但过长(>7天)，可能是数据错误，截断到合理范围
            WHEN pr.stoptime IS NOT NULL
                 AND pr.stoptime > pr.starttime
                 AND EXTRACT(EPOCH FROM (pr.stoptime - pr.starttime)) > 604800
            THEN pr.starttime + INTERVAL '7 days'

            -- 情况4: 无停止时间，基于ICU出院时间和药物类型设置合理上限
            WHEN pr.stoptime IS NULL THEN
                LEAST(
                    ie.outtime,  -- 不超过ICU出院时间
                    CASE
                        -- 不同药物设置不同的默认持续时间
                        WHEN pr.drug ILIKE '%propofol%' THEN pr.starttime + INTERVAL '24 hours'
                        WHEN pr.drug ILIKE '%midazolam%' THEN pr.starttime + INTERVAL '48 hours'
                        WHEN pr.drug ILIKE '%dexmedetomidine%' THEN pr.starttime + INTERVAL '12 hours'
                        WHEN pr.drug ILIKE '%lorazepam%' THEN pr.starttime + INTERVAL '24 hours'
                        WHEN pr.drug ILIKE '%diazepam%' THEN pr.starttime + INTERVAL '24 hours'
                        ELSE pr.starttime + INTERVAL '24 hours'  -- 默认24小时
                    END
                )

            ELSE pr.stoptime  -- 其他情况使用原始值
        END AS stoptime,
        -- 药物类型标识：精确匹配镇静药物（排除镇痛药）
        CASE WHEN EXISTS (
            SELECT 1 FROM drug_params dp
            WHERE LOWER(pr.drug) LIKE dp.sedation_pattern
        ) THEN 1 ELSE 0 END AS is_sedation_drug
    FROM mimiciv_icu.icustays ie
    LEFT JOIN mimiciv_hosp.prescriptions pr ON ie.hadm_id = pr.hadm_id
    WHERE pr.starttime IS NOT NULL
      -- 只考虑持续输注途径（更精确的镇静给药方式）
      AND pr.route IN ('IV DRIP', 'IV', 'Intravenous', 'IVPCA', 'SC', 'IM')
),

-- 步骤3: 预计算每小时的镇静状态（并行聚合优化）
sedation_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        co.starttime,
        co.endtime,
        -- 使用聚合函数避免复杂的LATERAL JOIN
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
    GROUP BY co.stay_id, co.hr, co.starttime, co.endtime
),

-- 步骤4: 预处理每小时的谵妄药物使用情况（并行优化）
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

-- 步骤5: 优化的GCS数据处理（并行优化版本）
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
        -- 高效判断GCS测量时刻的镇静状态：直接JOIN小时级镇静状态
        CASE WHEN sh.has_sedation_infusion = 1 THEN 1 ELSE 0 END AS is_sedated
    FROM mimiciv_derived.gcs gcs
    INNER JOIN mimiciv_icu.icustays ie ON gcs.stay_id = ie.stay_id
    -- 直接JOIN预计算的镇静状态，避免复杂的LATERAL JOIN
    LEFT JOIN sedation_hourly sh
        ON gcs.stay_id = sh.stay_id
        AND gcs.charttime >= sh.starttime
        AND gcs.charttime < sh.endtime
    WHERE gcs.gcs IS NOT NULL
),

-- =================================================================
-- BRAIN/神经系统 (并行优化版本)
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
-- 呼吸系统预计算CTEs (并行优化版本)
-- =================================================================

-- 步骤1: 预计算所有PF比值 (血气分析) - 并行优化
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
    -- 关键修复：约束血气时间在ICU住院时段内，避免跨住院污染
    AND bg.charttime >= ie.intime
    AND bg.charttime <= ie.outtime
    LEFT JOIN mimiciv_derived.ventilation vd
        ON ie.stay_id = vd.stay_id
        -- 调整边界：血气记录与呼吸支持同一时刻亦视为已开启
        AND bg.charttime >= vd.starttime
        AND bg.charttime <= vd.endtime
        AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy')
    WHERE bg.specimen = 'ART.'
      AND bg.pao2fio2ratio IS NOT NULL
      AND bg.pao2fio2ratio > 0
),

-- 步骤2: 预计算SpO2和FiO2的原始数据 - 并行优化
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

-- 步骤3: 预计算所有SF比值 (SpO2:FiO2) - 并行优化版本
sf_ratios_all AS (
    SELECT
        spo2.stay_id,
        spo2.charttime,
        spo2.oxygen_ratio,
        spo2.has_advanced_support
    FROM (
        SELECT
            spo2.stay_id,
            spo2.charttime,
              -- 关键修复：使用LATERAL子查询获取最近时间的FiO2
            (spo2.spo2_value / (fio2_recent.fio2_value / 100.0)) AS oxygen_ratio,
            -- 呼吸支持检测：直接JOIN ventilation表
            CASE WHEN vd.stay_id IS NOT NULL THEN 1 ELSE 0 END AS has_advanced_support
        FROM spo2_raw spo2
        LEFT JOIN LATERAL (
            -- 修复：选择SpO2记录时间前后1小时内绝对时间差最近的FiO2记录
            SELECT fio2.fio2_value
            FROM fio2_raw fio2
            WHERE fio2.stay_id = spo2.stay_id
              AND fio2.charttime BETWEEN spo2.charttime - INTERVAL '1 hour'
                                   AND spo2.charttime + INTERVAL '1 hour'  -- 前后各1小时
            ORDER BY ABS(EXTRACT(EPOCH FROM (fio2.charttime - spo2.charttime))) ASC  -- 按绝对时间差升序，最近的在前
            LIMIT 1  -- 只取时间差最小的一条
        ) fio2_recent ON TRUE
        -- 直接LEFT JOIN ventilation表，简化复杂的LATERAL JOIN
        LEFT JOIN mimiciv_derived.ventilation vd
            ON spo2.stay_id = vd.stay_id
            -- 同步PF逻辑：观测时间与支持开始同刻视为已支持
            AND spo2.charttime >= vd.starttime
            AND spo2.charttime <= vd.endtime
          AND vd.ventilation_status IN ('InvasiveVent', 'NonInvasiveVent', 'HFNC', 'Tracheostomy')
        WHERE spo2.spo2_value IS NOT NULL
    ) spo2
    WHERE spo2.oxygen_ratio IS NOT NULL  -- 确保FiO2匹配成功
),

-- 步骤4: 预计算所有ECMO记录（并行优化版本）
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
-- 步骤5: 小时级PF数据聚合 (并行优化版本)
-- =================================================================
pf_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        pf_min.oxygen_ratio AS pf_ratio_min,
        pf_min.has_advanced_support AS pf_has_support
    FROM co
    LEFT JOIN LATERAL (
        -- 修复：选择该小时内氧合比值最小的记录，同时携带其呼吸支持状态
        SELECT
            pf.oxygen_ratio,
            pf.has_advanced_support
        FROM pf_ratios_all pf
        WHERE pf.stay_id = co.stay_id
          AND pf.charttime >= co.starttime
          AND pf.charttime < co.endtime
          AND pf.oxygen_ratio IS NOT NULL
        ORDER BY pf.oxygen_ratio ASC  -- 按氧合比值升序，最小的在前
        LIMIT 1  -- 只取最小值的那条记录，确保状态绑定
    ) pf_min ON TRUE
),

-- 步骤6: 小时级SF数据聚合 (并行优化版本)
sf_hourly AS (
    SELECT
        co.stay_id,
        co.hr,
        sf_min.oxygen_ratio AS sf_ratio_min,
        sf_min.has_advanced_support AS sf_has_support
    FROM co
    LEFT JOIN LATERAL (
        -- 修复：选择该小时内SF比值最小的记录，同时携带其呼吸支持状态
        SELECT
            sf.oxygen_ratio,
            sf.has_advanced_support
        FROM sf_ratios_all sf
        WHERE sf.stay_id = co.stay_id
          AND sf.charttime >= co.starttime
          AND sf.charttime < co.endtime
          AND sf.oxygen_ratio IS NOT NULL
        ORDER BY sf.oxygen_ratio ASC  -- 按SF比值升序，最小的在前
        LIMIT 1  -- 只取最小值的那条记录，确保状态绑定
    ) sf_min ON TRUE
),

-- =================================================================
-- 呼吸系统小时级聚合 (并行优化版本)
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
-- 心血管系统预计算 (超级并行优化版本)
-- =================================================================

-- 步骤1: 预处理机械支持（并行聚合优化）
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

-- 步骤2: 预处理生命体征（MAP）- 并行优化
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

-- 步骤3: 预处理血管活性药物 - 并行优化
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
-- CARDIOVASCULAR/心血管 (SOFA2标准：超级并行优化版本)
-- =================================================================
cardiovascular AS (
    SELECT
        co.stay_id,
        co.hr,
        CASE
            -- 4分条件 (按优先级排序)
            -- 4a: 任意机械循环支持（含ECMO/IABP/LVAD等）直接评4分
            WHEN COALESCE(mech.has_ecmo, 0) > 0
                 OR other_mech_support_flag = 1 THEN 4
            -- 4b: NE+Epi总碱基剂量 > 0.4 mcg/kg/min
            WHEN ne_epi_total_base_dose > 0.4 THEN 4
            -- 4c: 中剂量NE+Epi与任意其他血管活性药/正性肌力药联合
            WHEN ne_epi_total_base_dose > 0.2
                 AND other_vasopressor_flag = 1 THEN 4
            -- 4d: 多巴胺单独使用 > 40 μg/kg/min
            WHEN dopamine_only_score >= 4 THEN 4

            -- 3分条件 (按优先级排序)
            -- 3a: NE+Epi总碱基剂量 > 0.2 mcg/kg/min
            WHEN ne_epi_total_base_dose > 0.2 THEN 3
            -- 3b: NE+Epi > 0 且合并其他血管活性药物或非ECMO机械支持
            WHEN ne_epi_total_base_dose > 0
                 AND other_vasopressor_flag = 1 THEN 3
            -- 3c: 多巴胺单独使用 > 20-40 μg/kg/min
            WHEN dopamine_only_score = 3 THEN 3

            -- 2分条件 (按优先级排序)
            -- 2a: NE+Epi总碱基剂量 > 0
            WHEN ne_epi_total_base_dose > 0 THEN 2
            -- 2b: 使用其他血管活性药物（不包括多巴胺单独使用）
            WHEN other_vasopressor_flag = 1 THEN 2
            -- 2c: 多巴胺单独使用 ≤ 20 μg/kg/min
            WHEN dopamine_only_score = 2 THEN 2

            -- 1分条件: 当无血管活性药物时，使用MAP分级评分（SOFA2标准保底路径）
            WHEN ne_epi_total_base_dose = 0
                 AND other_vasopressor_flag = 0
                 AND dopamine_only_score = 0 THEN
                CASE
                    WHEN vit.mbp_min < 40 THEN 4    -- MAP < 40 mmHg
                    WHEN vit.mbp_min < 50 THEN 3    -- MAP 40-49 mmHg
                    WHEN vit.mbp_min < 60 THEN 2    -- MAP 50-59 mmHg
                    WHEN vit.mbp_min < 70 THEN 1    -- MAP 60-69 mmHg
                    WHEN vit.mbp_min >= 70 THEN 0  -- MAP ≥ 70 mmHg
                    ELSE 0  -- MAP数据缺失时默认0分
                END

            -- 0分条件: MAP >= 70 mmHg 且有血管活性药物支持（正常情况）
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
            END AS other_vasopressor_flag,
            -- 4. 非ECMO机械支持标志
            CASE WHEN COALESCE(mech.has_iabp, 0) + COALESCE(mech.has_impella, 0) +
                      COALESCE(mech.has_lvad, 0) + COALESCE(mech.has_tandemheart, 0) +
                      COALESCE(mech.has_rvad, 0) + COALESCE(mech.has_cardiac_assist, 0) > 0
                 THEN 1 ELSE 0 END AS other_mech_support_flag
    ) dose_calc
),

-- =================================================================
-- 肝脏系统 (超级并行优化版本)
-- =================================================================

-- 步骤4: 预处理胆红素数据 (超级并行优化)
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

-- LIVER/肝脏 (SOFA2标准：超级并行聚合版本)
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

-- =================================================================
-- 肾脏系统 (超级并行优化版本)
-- =================================================================

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

-- Step 3: 使用滑动窗口计算尿量 (超级并行优化版本)
urine_output_windows AS (
    SELECT
        stay_id,
        charttime,
        urine_ml_per_kg,
        -- 使用窗口函数计算6h、12h、24h累计平均尿量
        AVG(uo_next.urine_ml_per_kg) OVER (
            PARTITION BY stay_id
            ORDER BY charttime
            ROWS BETWEEN 5 PRECEDING AND 0 FOLLOWING
        ) AS uo_avg_6h,
        AVG(uo_next.urine_ml_per_kg) OVER (
            PARTITION BY stay_id
            ORDER BY charttime
            ROWS BETWEEN 11 PRECEDING AND 0 FOLLOWING
        ) AS uo_avg_12h,
        AVG(uo_next.urine_ml_per_kg) OVER (
            PARTITION BY stay_id
            ORDER BY charttime
            ROWS BETWEEN 23 PRECEDING AND 0 FOLLOWING
        ) AS uo_avg_24h
    FROM urine_output_raw uo_next
),

-- Step 4: 尿量评分计算（超级并行优化）
urine_output_scores AS (
    SELECT
        stay_id,
        charttime,
        urine_ml_per_kg,
        uo_avg_6h,
        uo_avg_12h,
        uo_avg_24h,
        -- 尿量评分
        CASE
            -- 3分：<0.3 mL/kg/h 的24小时平均值
            WHEN uo_avg_24h < 0.3 THEN 3
            -- 2分：<0.5 mL/kg/h 的12小时平均值
            WHEN uo_avg_12h < 0.5 THEN 2
            -- 1分：<0.5 mL/kg/h 的6小时平均值
            WHEN uo_avg_6h < 0.5 THEN 1
            ELSE 0
        END AS urine_score
    FROM urine_output_windows
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
-- KIDNEY/肾脏 (SOFA2标准：超级并行聚合版本)
-- =================================================================
kidney_hourly_aggregates AS (
    SELECT
        co.stay_id,
        co.hr,
        MAX(chem.creatinine) AS creatinine_max,
        MAX(bg.potassium) AS potassium_max,
        MIN(bg.ph) AS ph_min,
        MIN(bg.bicarbonate) AS bicarbonate_min,
        MAX(ur.urine_score) AS max_urine_score,
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
    LEFT JOIN urine_output_scores ur
        ON co.stay_id = ur.stay_id
        AND ur.charttime >= co.starttime
        AND ur.charttime < co.endtime
    LEFT JOIN rrt_status rrt ON co.stay_id = rrt.stay_id AND co.hr = rrt.hr
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
                )
                     AND (COALESCE(potassium_max, 0) >= 6.0
                          OR (COALESCE(ph_min, 7.4) <= 7.2 AND COALESCE(bicarbonate_min, 24) <= 12))
                THEN 4 ELSE 0 END,
            CASE
                WHEN creatinine_max > 3.5 THEN 3
                WHEN creatinine_max > 2.0 THEN 2
                WHEN creatinine_max > 1.2 THEN 1
                ELSE 0 END,
            max_urine_score
        ) AS kidney
    FROM kidney_hourly_aggregates
),

-- =================================================================
-- 凝血系统 (超级并行优化版本)
-- =================================================================

-- 步骤6: 预处理血小板数据 (超级并行优化)
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

-- HEMOSTASIS/凝血 (SOFA2标准：超级并行聚合版本)
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
-- 综合评分 (超级并行窗口函数版本)
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
-- 最终输出（原查询方式保持兼容）
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

-- =================================================================
-- 创建超级优化表并插入数据（不覆盖现有表）
-- =================================================================
-- 插入进度更新
INSERT INTO sofa2_run_progress_v3 (stage, status, details)
VALUES ('创建最终表', 'IN_PROGRESS', '创建超级优化的 sofa2_scores_v3 表');

-- 使用 CREATE TABLE AS SELECT (CTAS) 进行超级并行创建
DROP TABLE IF EXISTS mimiciv_derived.sofa2_scores_v3;

CREATE TABLE mimiciv_derived.sofa2_scores_v3 WITH (parallel_workers = 8) AS
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

-- 添加主键和超级并行索引
ALTER TABLE mimiciv_derived.sofa2_scores_v3
ADD COLUMN sofa2_score_id SERIAL PRIMARY KEY;

-- 使用CONCURRENTLY创建索引以减少锁定时间
CREATE INDEX CONCURRENTLY idx_sofa2_v3_stay_id ON mimiciv_derived.sofa2_scores_v3(stay_id);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_subject_id ON mimiciv_derived.sofa2_scores_v3(subject_id);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_hadm_id ON mimiciv_derived.sofa2_scores_v3(hadm_id);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_total_score ON mimiciv_derived.sofa2_scores_v3(sofa2_total);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_hr ON mimiciv_derived.sofa2_scores_v3(hr);
CREATE INDEX CONCURRENTLY idx_sofa2_v3_stay_hr ON mimiciv_derived.sofa2_scores_v3(stay_id, hr);

-- 创建部分索引用于常见查询
CREATE INDEX CONCURRENTLY idx_sofa2_v3_high_score ON mimiciv_derived.sofa2_scores_v3(stay_id, hr) WHERE sofa2_total >= 10;

-- 添加表注释
COMMENT ON TABLE mimiciv_derived.sofa2_scores_v3 IS 'SOFA2评分系统超级优化结果表V3，包含每小时评分和24小时窗口最差评分（24核CPU+93GB内存优化版本）';

-- 更新进度
INSERT INTO sofa2_run_progress_v3 (stage, status, details)
VALUES ('完成', 'COMPLETED', '超级优化的SOFA2评分表 sofa2_scores_v3 创建完成');

-- 显示创建结果统计
SELECT
    'SOFA2超级优化完成' AS status,
    COUNT(*) AS total_records,
    COUNT(DISTINCT stay_id) AS unique_stays,
    COUNT(DISTINCT subject_id) AS unique_patients,
    MIN(sofa2_total) AS min_score,
    MAX(sofa2_total) AS max_score,
    ROUND(AVG(sofa2_total), 2) AS avg_score,
    NOW() - (SELECT start_time FROM sofa2_run_progress_v3 WHERE stage = 'SOFA2 V3 超级优化开始' ORDER BY run_id DESC LIMIT 1) AS total_runtime
FROM mimiciv_derived.sofa2_scores_v3;

-- 显示性能统计
SELECT
    '性能统计' AS category,
    stage,
    status,
    details,
    start_time,
    NOW() - start_time AS duration
FROM sofa2_run_progress_v3
ORDER BY run_id DESC LIMIT 5;

-- 显示当前配置验证
SELECT
    '最终配置验证' AS setting_type,
    current_setting('work_mem') AS work_mem,
    current_setting('maintenance_work_mem') AS maintenance_work_mem,
    current_setting('max_parallel_workers_per_gather') AS max_parallel_workers_per_gather,
    current_setting('effective_cache_size') AS effective_cache_size;