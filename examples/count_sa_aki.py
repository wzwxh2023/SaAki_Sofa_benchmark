"""
任务：统计MIMIC-IV中SA-AKI患者数量
（Claude自动生成此脚本）
"""

import sys
sys.path.append('/mnt/f/SaAki_Sofa_benchmark')
from utils.db_helper import query_to_df

print("正在查询MIMIC-IV中的SA-AKI患者数量...\n")

# Claude自动生成优化的SQL
sql = """
WITH sepsis_patients AS (
    SELECT DISTINCT stay_id
    FROM mimiciv_derived.sepsis3
    WHERE sepsis3 = true
),
aki_patients AS (
    SELECT DISTINCT stay_id
    FROM mimiciv_derived.kdigo_stages
    WHERE aki_stage >= 1
)
SELECT
    COUNT(DISTINCT s.stay_id) as total_sa_aki_patients
FROM sepsis_patients s
INNER JOIN aki_patients a ON s.stay_id = a.stay_id;
"""

result = query_to_df(sql, db='mimic')

print("="*60)
print("统计结果")
print("="*60)
print(f"📊 SA-AKI患者总数: {result.iloc[0]['total_sa_aki_patients']:,}")
print("="*60)

# 进一步分析：按AKI分期统计
print("\n按AKI分期详细统计:")

sql_by_stage = """
WITH sepsis_patients AS (
    SELECT DISTINCT stay_id
    FROM mimiciv_derived.sepsis3
    WHERE sepsis3 = true
)
SELECT
    k.aki_stage,
    COUNT(DISTINCT k.stay_id) as patient_count,
    ROUND(100.0 * COUNT(DISTINCT k.stay_id) / SUM(COUNT(DISTINCT k.stay_id)) OVER (), 1) as percentage
FROM mimiciv_derived.kdigo_stages k
INNER JOIN sepsis_patients s ON k.stay_id = s.stay_id
WHERE k.aki_stage >= 1
GROUP BY k.aki_stage
ORDER BY k.aki_stage;
"""

result_by_stage = query_to_df(sql_by_stage, db='mimic')
print(result_by_stage.to_string(index=False))

print("\n✅ 查询完成！")
```

**看到了吗？** 您只需要说需求，我会：
1. 自动写SQL（而且是优化过的）
2. 自动执行
3. 自动格式化输出
4. 自动做进一步分析

**您完全不需要记SQL语法！**

---

## 🎯 下一步行动建议

### 方案1：现在就试试Claude Code工作流（推荐）

**第1步：配置数据库连接**（5分钟）

修改我刚创建的配置文件：

```bash
# 编辑配置文件
nano /mnt/f/SaAki_Sofa_benchmark/utils/db_helper.py

# 找到这几行并修改：
DB_CONFIG = {
    'mimic': {
        'host': WINDOWS_HOST,
        'port': 5432,
        'database': 'mimiciv',      # 您的数据库名
        'user': 'your_username',    # 改成您的用户名
        'password': 'your_password' # 改成您的密码
    },
    # ...
}
```

**第2步：测试连接**（2分钟）

```bash
# 在WSL终端中
cd /mnt/f/SaAki_Sofa_benchmark
python utils/db_helper.py
```

如果看到 `✅ 连接成功！`，就OK了！

**第3步：试试查询**（1分钟）

```bash
python examples/count_sa_aki.py
```

---

### 方案2：先继续用Navicat，逐步过渡

**第1步**：继续在Navicat中查看数据库结构、测试SQL

**第2步**：把Navicat导出的CSV放到 `/mnt/f/SaAki_Sofa_benchmark/data/`

**第3步**：告诉我："帮我分析这个CSV"

---

## ✨ Claude Code的超级优势

相比Navicat，在Claude Code环境下：

1. **我可以帮您写SQL** - 不需要记复杂语法
2. **我可以帮您写Python** - 数据分析代码自动生成
3. **我可以解释错误** - 遇到问题立即告诉我
4. **我可以优化查询** - 自动优化慢查询
5. **完全可重现** - 所有操作都是代码，可以重复运行
6. **一站式** - 查询→分析→可视化→导出，一个环境搞定

---

## 🤔 总结

**您的担心**："WSL没有图形界面，不如Navicat直观"

**实际情况**：
- ✅ VSCode有数据库插件，**有图形界面**（类似Navicat）
- ✅ Claude Code可以帮您写所有代码，**比手动点击更快**
- ✅ Python查询结果可以在VSCode中**表格形式显示**
- ✅ 整个流程**自动化、可重现、可协作**

**我的建议**：
1. **先按照我上面的步骤配置好环境**（10分钟）
2. **试试运行一个查询**（感受一下工作流）
3. **如果不习惯，随时可以回到Navicat**

现在要不要我帮您：
1. **配置数据库连接**（我指导您一步步操作）
2. **或者先看看VSCode的数据库插件**（安装SQLTools）
3. **或者直接开始写SQL查询脚本**

您想从哪个开始？🚀