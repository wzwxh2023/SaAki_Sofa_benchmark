-- 创建存储过程用于分批处理SOFA-2评分
-- =================================================================

CREATE OR REPLACE FUNCTION process_sofa2_batch(
    p_batch_size INTEGER DEFAULT 100,
    p_batch_offset INTEGER DEFAULT 0,
    p_output_table TEXT DEFAULT 'sofa2_results'
) RETURNS TEXT AS $$
DECLARE
    v_start_time TIMESTAMP := clock_timestamp();
    v_records_processed INTEGER := 0;
    v_batch_count INTEGER := 0;
    v_sql TEXT;
BEGIN
    -- 创建结果表（如果不存在）
    v_sql := FORMAT('
        CREATE TABLE IF NOT EXISTS %I (
            batch_id TEXT,
            stay_id INTEGER,
            hadm_id INTEGER,
            subject_id INTEGER,
            hr INTEGER,
            starttime TIMESTAMP,
            endtime TIMESTAMP,
            ratio_type TEXT,
            oxygen_ratio NUMERIC,
            has_advanced_support INTEGER,
            on_ecmo INTEGER,
            brain INTEGER,
            respiratory INTEGER,
            cardiovascular INTEGER,
            liver INTEGER,
            kidney INTEGER,
            hemostasis INTEGER,
            sofa2_total INTEGER,
            processed_at TIMESTAMP DEFAULT NOW()
        );
    ', p_output_table);
    EXECUTE v_sql;

    -- 获取要处理的stay_id列表
    WITH target_stays AS (
        SELECT stay_id
        FROM mimiciv_derived.icustay_hourly
        WHERE hr BETWEEN 0 AND 24
        ORDER BY stay_id
        LIMIT p_batch_size OFFSET p_batch_offset
    )

    -- 计算并插入本批结果
    INSERT INTO %I (batch_id, stay_id, hadm_id, subject_id, hr, starttime, endtime,
                    ratio_type, oxygen_ratio, has_advanced_support, on_ecmo,
                    brain, respiratory, cardiovascular, liver, kidney, hemostasis, sofa2_total)

    -- [这里放置完整的SOFA-2计算CTE，但需要修改基础CTE]

    -- 修改的基础CTE，仅处理本批次患者
    WITH co AS (
        SELECT ih.stay_id, ie.hadm_id, ie.subject_id
            , hr
            , ih.endtime - INTERVAL '1 HOUR' AS starttime
            , ih.endtime
        FROM mimiciv_derived.icustay_hourly ih
        INNER JOIN mimiciv_icu.icustays ie ON ih.stay_id = ie.stay_id
        INNER JOIN target_stays ts ON ih.stay_id = ts.stay_id
        WHERE ih.hr BETWEEN 0 AND 24
    ),

    -- [继续使用所有其他CTE...]

    -- 最终选择（简化版示例）
    SELECT
        'BATCH_' || p_batch_offset::TEXT as batch_id,
        stay_id, hadm_id, subject_id, hr, starttime, endtime,
        ratio_type, oxygen_ratio, has_advanced_support, on_ecmo,
        brain, respiratory, cardiovascular, liver, kidney, hemostasis,
        (COALESCE(brain, 0) + COALESCE(respiratory, 0) + COALESCE(cardiovascular, 0) +
         COALESCE(liver, 0) + COALESCE(kidney, 0) + COALESCE(hemostasis, 0)) AS sofa2_total
    FROM scorecomp
    WHERE hr >= 0;

    GET DIAGNOSTICS v_records_processed = ROW_COUNT;
    v_batch_count := p_batch_offset + p_batch_size;

    -- 返回处理结果摘要
    RETURN FORMAT('批次处理完成: 处理了 %s 条记录，涵盖 %s-%s 范围的患者，耗时 %s',
                  v_records_processed,
                  p_batch_offset,
                  v_batch_count - 1,
                  clock_timestamp() - v_start_time);

EXCEPTION
    WHEN OTHERS THEN
        RETURN '错误: ' || SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- 使用示例
-- SELECT process_sofa2_batch(50, 0);  -- 处理前50个患者
-- SELECT process_sofa2_batch(50, 50); -- 处理第51-100个患者