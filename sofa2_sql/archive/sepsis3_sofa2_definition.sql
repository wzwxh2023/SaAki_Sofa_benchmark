-- =================================================================
-- 基于SOFA2评分表的脓毒症3.0定义脚本
-- 参考origin_sofa_sql/sepsis3.sql，使用sofa2_scores表替代原始sofa表
-- 脓毒症定义：可疑感染 + SOFA2评分 >= 2
-- =================================================================
DROP TABLE IF EXISTS mimiciv_derived.sepsis3_sofa2_onset CASCADE;
-- 创建表
CREATE TABLE mimiciv_derived.sepsis3_sofa2_onset AS
WITH sofa2 AS (
    SELECT
        stay_id,
        starttime,
        endtime,
        brain,
        respiratory,
        cardiovascular,
        liver,
        kidney,
        hemostasis,
        sofa2_total AS sofa2_score
    FROM mimiciv_derived.sofa2_scores_hr_filtered
    WHERE sofa2_total >= 2
),

-- 主查询：结合可疑感染和SOFA2评分
s1 AS (
    SELECT
        soi.subject_id,
        soi.stay_id,
        soi.hadm_id,
        -- 可疑感染相关列
        soi.ab_id,
        soi.antibiotic,
        soi.antibiotic_time,
        soi.culture_time,
        soi.suspected_infection,
        soi.suspected_infection_time,
        soi.specimen,
        soi.positive_culture,
        -- SOFA2相关列
        s2.starttime,
        s2.endtime,
        s2.brain,
        s2.respiratory,
        s2.cardiovascular,
        s2.liver,
        s2.kidney,
        s2.hemostasis,
        s2.sofa2_score,
        -- 脓毒症-3定义：SOFA2 >= 2 且有可疑感染
        s2.sofa2_score >= 2 AND soi.suspected_infection = 1 AS sepsis3_sofa2,
        -- 选择最早的可疑感染/抗生素/SOFA2记录
        ROW_NUMBER() OVER
        (
            PARTITION BY soi.stay_id
            ORDER BY
                soi.suspected_infection_time,
                soi.antibiotic_time,
                soi.culture_time,
                s2.endtime
        ) AS rn_sus
    FROM mimiciv_derived.suspicion_of_infection AS soi
    INNER JOIN sofa2 AS s2
        ON soi.stay_id = s2.stay_id
            AND s2.endtime >= (soi.suspected_infection_time - INTERVAL '48 hours')
            AND s2.endtime <= (soi.suspected_infection_time + INTERVAL '24 hours')
    -- 仅包括ICU内的记录
    WHERE soi.stay_id IS NOT NULL
)

SELECT
    subject_id,
    stay_id,
    hadm_id,
    -- 注意：在此时可能给予了多种抗生素
    antibiotic_time,
    -- 培养时间可能是日期而非精确时间
    culture_time,
    suspected_infection_time,
    -- endtime是SOFA2评分有效的最晚时间
    endtime AS sofa2_time,
    sofa2_score,
    brain,
    respiratory,
    cardiovascular,
    liver,
    kidney,
    hemostasis,
    sepsis3_sofa2
FROM s1
WHERE rn_sus = 1;