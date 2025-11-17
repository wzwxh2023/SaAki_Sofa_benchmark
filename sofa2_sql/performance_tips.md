# SOFA-2 分批处理性能优化指南

## 🚀 **推荐策略（从优到差）**

### 1. **直接修改LIMIT（最简单）**
```sql
-- 在原文件第17行修改：
-- 原：AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly LIMIT 50)
-- 改为：AND ih.stay_id IN (SELECT stay_id FROM mimiciv_derived.icustay_hourly ORDER BY stay_id LIMIT 100 OFFSET 0)
-- 第二批：OFFSET 100，第三批：OFFSET 200，以此类推
```

### 2. **使用自动化脚本（最便捷）**
```bash
# 运行自动化分批脚本
./batch_processing_script.sh
```

### 3. **数据库端处理（最高效）**
```sql
-- 创建存储过程后，循环执行
SELECT process_sofa2_batch(100, 0);
SELECT process_sofa2_batch(100, 100);
SELECT process_sofa2_batch(100, 200);
```

## 📊 **批次大小建议**

| 数据库配置 | 推荐批次大小 | 预估时间 |
|-----------|-------------|---------|
| 本地开发环境 | 20-50个患者 | 2-10分钟 |
| 中等服务器 | 100-200个患者 | 10-30分钟 |
| 高性能服务器 | 500-1000个患者 | 30-60分钟 |

## ⚡ **额外优化技巧**

### 1. **索引检查**
```sql
-- 确保这些索引存在
CREATE INDEX IF NOT EXISTS idx_icustay_hourly_stay_hr ON mimiciv_derived.icustay_hourly(stay_id, hr);
CREATE INDEX IF NOT EXISTS idx_gcs_stay_time ON mimiciv_derived.gcs(stay_id, charttime);
CREATE INDEX IF NOT EXISTS idx_ventilation_stay ON mimiciv_derived.ventilation(stay_id);
```

### 2. **内存设置**
```sql
-- 在psql中执行（需要超级用户权限）
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';
SET shared_buffers = '256MB';
```

### 3. **并行处理**
```sql
-- 启用并行查询
SET max_parallel_workers_per_gather = 4;
SET parallel_tuple_cost = 1000;
SET parallel_setup_cost = 1000;
```

### 4. **临时表优化**
```sql
-- 对于大批次，考虑使用临时表
CREATE TEMPORARY TABLE temp_stays AS
SELECT stay_id FROM mimiciv_derived.icustay_hourly
WHERE stay_id BETWEEN 300000 AND 300100;

CREATE INDEX ON temp_stays(stay_id);
```

## 🔍 **监控和调试**

### 查看进度
```sql
-- 查看已完成的记录数
SELECT COUNT(*) FROM sofa2_results;
SELECT DISTINCT batch_id, COUNT(*) FROM sofa2_results GROUP BY batch_id;
```

### 检查错误
```sql
-- 查看最近的错误日志
SELECT * FROM pg_stat_activity WHERE state = 'active';
```

## 📋 **最佳实践**

1. **测试先行**：先用小批次（10个患者）测试
2. **逐步增加**：确认无误后再增大批次
3. **定期保存**：每批次完成后立即保存结果
4. **备份数据**：处理前备份重要数据
5. **监控资源**：注意数据库CPU和内存使用率

## 🆘 **常见问题解决**

### 超时问题
- 增加 `statement_timeout`：`SET statement_timeout = '300s';`
- 减小批次大小
- 检查网络连接稳定性

### 内存不足
- 减小 `work_mem` 参数
- 使用临时表减少内存使用
- 分批更小处理

### 锁等待
- 在非高峰时段执行
- 使用 `NOWAIT` 选项避免长时间等待