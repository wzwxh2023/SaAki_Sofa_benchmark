-- =================================================================
-- SOFA2药物映射优化版本 - 消除模糊匹配性能瓶颈
-- =================================================================

-- 创建精确的药物映射表，避免每次模糊匹配
CREATE TEMP TABLE sedation_drug_mapping AS
SELECT 'propofol' AS drug_name, '%propofol%' AS pattern
UNION ALL SELECT 'midazolam', '%midazolam%'
UNION ALL SELECT 'lorazepam', '%lorazepam%'
UNION ALL SELECT 'diazepam', '%diazepam%'
UNION ALL SELECT 'dexmedetomidine', '%dexmedetomidine%'
UNION ALL SELECT 'ketamine', '%ketamine%'
UNION ALL SELECT 'clonidine', '%clonidine%'
UNION ALL SELECT 'etomidate', '%etomidate%';

CREATE TEMP TABLE delirium_drug_mapping AS
SELECT 'haloperidol' AS drug_name, '%haloperidol%' AS pattern
UNION ALL SELECT 'haldol', '%haldol%'
UNION ALL SELECT 'quetiapine', '%quetiapine%'
UNION ALL SELECT 'seroquel', '%seroquel%'
UNION ALL SELECT 'olanzapine', '%olanzapine%'
UNION ALL SELECT 'zyprexa', '%zyprexa%'
UNION ALL SELECT 'risperidone', '%risperidone%'
UNION ALL SELECT 'risperdal', '%risperdal%'
UNION ALL SELECT 'ziprasidone', '%ziprasidone%'
UNION ALL SELECT 'geodon', '%geodon%'
UNION ALL SELECT 'clozapine', '%clozapine%'
UNION ALL SELECT 'aripiprazole', '%aripiprazole%';

-- 预处理prescriptions表，一次性标记所有药物类型
CREATE TEMP TABLE classified_prescriptions AS
SELECT
    pr.hadm_id,
    pr.starttime,
    pr.stoptime,
    pr.route,
    pr.drug,
    -- 预计算药物分类，避免重复模糊匹配
    CASE
        WHEN LOWER(pr.drug) LIKE '%propofol%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%midazolam%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%lorazepam%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%diazepam%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%dexmedetomidine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%ketamine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%clonidine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%etomidate%' THEN 1
        ELSE 0
    END AS is_sedation_drug,
    CASE
        WHEN LOWER(pr.drug) LIKE '%haloperidol%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%haldol%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%quetiapine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%seroquel%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%olanzapine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%zyprexa%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%risperidone%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%risperdal%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%ziprasidone%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%geodon%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%clozapine%' THEN 1
        WHEN LOWER(pr.drug) LIKE '%aripiprazole%' THEN 1
        ELSE 0
    END AS is_delirium_drug
FROM mimiciv_hosp.prescriptions pr
WHERE pr.starttime IS NOT NULL
  AND pr.route IN ('IV DRIP', 'IV', 'Intravenous', 'IVPCA', 'SC', 'IM');

-- 统计结果
SELECT
    '药物分类统计' as info,
    COUNT(*) as total_prescriptions,
    COUNT(CASE WHEN is_sedation_drug = 1 THEN 1 END) as sedation_drugs,
    COUNT(CASE WHEN is_delirium_drug = 1 THEN 1 END) as delirium_drugs,
    COUNT(CASE WHEN is_sedation_drug = 1 OR is_delirium_drug = 1 THEN 1 END) as target_drugs
FROM classified_prescriptions;