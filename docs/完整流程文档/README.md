# MIMIC-IV 项目完整文档

**项目**: SaAki_Sofa_benchmark - MIMIC-IV 数据分析
**创建日期**: 2025年11月14日
**状态**: ✅ 完成并可用

---

## 📚 文档目录

### 核心文档（中文）

| 文档 | 说明 | 适用对象 |
|------|------|----------|
| [01_完整流程总结.md](./01_完整流程总结.md) | 从技能创建到数据库连接的完整流程 | 所有用户 |
| [02_快速开始指南.md](./02_快速开始指南.md) | 5分钟快速开始数据分析 | 新手用户 |
| [03_关键资源速查表.md](./03_关键资源速查表.md) | 表名、ItemID、SQL 模式快速参考 | 日常使用 |

### 技能文档（英文）

| 文档 | 位置 | 说明 |
|------|------|------|
| SKILL.md | `.claude/skills/mimiciv-data-extraction/` | 完整的 MIMIC-IV 数据提取技能（28KB） |
| README.md | `.claude/skills/mimiciv-data-extraction/` | 技能使用指南 |
| skill.json | `.claude/skills/mimiciv-data-extraction/` | 技能元数据 |

### 数据库文档（英文）

| 文档 | 位置 | 说明 |
|------|------|------|
| MIMICIV_Database_Summary.md | 项目根目录 | 完整的数据库结构和统计摘要 |
| 配置步骤_PostgreSQL连接.md | 项目根目录 | PostgreSQL 连接配置指南 |

---

## 🚀 快速导航

### 第一次使用？

1. 阅读 [完整流程总结](./01_完整流程总结.md) 了解整个项目
2. 参考 [快速开始指南](./02_快速开始指南.md) 开始第一个查询
3. 使用 [关键资源速查表](./03_关键资源速查表.md) 作为日常参考

### 需要写 SQL 查询？

- 查看 [关键资源速查表](./03_关键资源速查表.md) 获取：
  - 常用 ItemID
  - SQL 模式模板
  - 表结构参考

### 需要深入了解？

- 阅读 [SKILL.md](../.claude/skills/mimiciv-data-extraction/SKILL.md) 获取：
  - 完整表结构文档
  - 详细的临床概念实现
  - 性能优化技巧
  - 数据质量处理方法

### 需要数据库统计？

- 查看 [MIMICIV_Database_Summary.md](../../MIMICIV_Database_Summary.md) 获取：
  - 所有表的行数
  - 数据库大小
  - 预计算表列表
  - 快速查询示例

---

## 📊 项目结构概览

```
/mnt/f/SaAki_Sofa_benchmark/
│
├── .claude/
│   └── skills/
│       └── mimiciv-data-extraction/      # MIMIC-IV 技能
│           ├── SKILL.md                  # 核心技能内容 (28KB)
│           ├── README.md                 # 使用指南
│           └── skill.json                # 元数据
│
├── docs/
│   └── 完整流程文档/                      # 本文档目录
│       ├── README.md                     # 文档索引（本文件）
│       ├── 01_完整流程总结.md             # 完整流程
│       ├── 02_快速开始指南.md             # 快速开始
│       └── 03_关键资源速查表.md           # 速查表
│
├── utils/
│   └── db_helper.py                      # 数据库连接工具 ✅ 已配置
│
├── scripts/
│   ├── explore_mimiciv_database.py       # 数据库探索
│   └── get_actual_row_counts.py          # 行数统计
│
├── examples/
│   ├── skill_demonstration.py            # 技能演示
│   ├── quick_query_example.py            # 快速查询示例
│   └── count_sa_aki.py                   # SA-AKI 统计
│
├── configs/
│   └── mimiciv_unified.json              # Skill-seekers 配置
│
├── MIMICIV_Database_Summary.md           # 数据库摘要
└── 配置步骤_PostgreSQL连接.md             # 连接配置指南
```

---

## ✅ 已完成的工作

### 1. 技能创建
- ✅ 安装 skill-seekers 工具
- ✅ 从 MIMIC-IV 官方文档提取信息
- ✅ 从 GitHub 仓库提取 SQL 示例
- ✅ 创建完整的 MIMIC-IV 数据提取技能（28KB）
- ✅ 包含所有表结构、ItemID、临床概念实现

### 2. 数据库连接
- ✅ 配置 PostgreSQL 连接参数
  - 主机: 172.19.160.1
  - 端口: 5432
  - 数据库: mimiciv
  - 用户: postgres
- ✅ 安装 Python 依赖（psycopg2, sqlalchemy）
- ✅ 测试连接成功

### 3. 数据库探索
- ✅ 发现 3 个 schemas（hosp, icu, derived）
- ✅ 列出 111 个表
- ✅ 获取实际行数统计
- ✅ 分析表关系和外键
- ✅ 发现预计算表（SOFA、Sepsis、AKI 等）

### 4. 文档创建
- ✅ 完整流程文档（中文）
- ✅ 快速开始指南（中文）
- ✅ 关键资源速查表（中文）
- ✅ 数据库摘要（英文）
- ✅ 技能文档（英文）

### 5. 工具脚本
- ✅ 数据库连接工具（db_helper.py）
- ✅ 数据库探索脚本
- ✅ 行数统计脚本
- ✅ 示例查询脚本

---

## 🎯 关键成果

### 可用数据
- **364,627** 患者
- **546,028** 住院记录
- **94,458** ICU 住院
- **41,295** 脓毒症病例（已识别）
- **超过 6.2 亿** 临床事件

### 预计算表（重要！）
你的数据库包含已经计算好的临床概念，无需从头计算：
- ✅ SOFA 评分（完整时间序列 + 首日）
- ✅ Sepsis-3 识别
- ✅ KDIGO AKI 分期
- ✅ 首日实验室值和生命体征
- ✅ 血管活性药物记录
- ✅ 机械通气时段

### 工具和技能
- ✅ Python 数据库连接工具
- ✅ MIMIC-IV 数据提取技能（包含 SQL 模式和 ItemID 参考）
- ✅ 完整的中英文文档

---

## 🔧 常用操作

### 测试数据库连接
```bash
cd /mnt/f/SaAki_Sofa_benchmark
conda activate rna-seq
python -c "from utils.db_helper import test_connection; test_connection('mimic')"
```

### 快速查询
```python
from utils.db_helper import query_to_df

# 获取脓毒症患者
df = query_to_df("""
    SELECT * FROM mimiciv_derived.sepsis3
    WHERE sepsis3 = true LIMIT 10;
""", db='mimic')

print(df)
```

### 查看技能文档
```bash
# 完整技能（包含所有 SQL 模式）
cat .claude/skills/mimiciv-data-extraction/SKILL.md

# 快速指南
cat .claude/skills/mimiciv-data-extraction/README.md
```

### 查看数据库摘要
```bash
cat MIMICIV_Database_Summary.md
```

---

## 📖 学习路径

### Level 1: 入门（第1天）
1. 阅读 [快速开始指南](./02_快速开始指南.md)
2. 运行第一个查询
3. 熟悉 `db_helper.py` 工具

### Level 2: 熟悉（第1周）
1. 学习 [关键资源速查表](./03_关键资源速查表.md)
2. 理解常用 ItemID
3. 练习 SQL 查询模式
4. 探索预计算表

### Level 3: 精通（第1月）
1. 深入研究 [SKILL.md](../.claude/skills/mimiciv-data-extraction/SKILL.md)
2. 实现复杂的临床概念
3. 优化查询性能
4. 构建自己的分析流程

---

## 💡 使用技巧

### 1. 优先使用预计算表
```python
# ✅ 推荐：使用预计算表（快速）
df = query_to_df("SELECT * FROM mimiciv_derived.sepsis3", db='mimic')

# ❌ 不推荐：从原始数据计算（慢）
# df = query_to_df("SELECT ... FROM mimiciv_icu.chartevents ...", db='mimic')
```

### 2. 始终先用 LIMIT 测试
```python
# 先测试
df = query_to_df(sql + " LIMIT 100", db='mimic')
print(f"返回 {len(df)} 行")

# 确认后再全量
df_full = query_to_df(sql, db='mimic')
```

### 3. 参考技能文档
```python
# 在 Claude Code 中请求帮助
"使用 MIMIC-IV 技能，帮我提取脓毒症患者的首日 SOFA 评分"
```

### 4. 善用速查表
- 需要 ItemID？→ 查看速查表
- 需要 SQL 模式？→ 查看速查表
- 需要表名？→ 查看速查表

---

## 🆘 获取帮助

### 查阅文档
1. 日常查询：[关键资源速查表](./03_关键资源速查表.md)
2. 快速开始：[快速开始指南](./02_快速开始指南.md)
3. 完整参考：[SKILL.md](../.claude/skills/mimiciv-data-extraction/SKILL.md)
4. 数据库信息：[MIMICIV_Database_Summary.md](../../MIMICIV_Database_Summary.md)

### 使用 Claude Code
在对话中提问时引用技能：
```
"使用 MIMIC-IV 技能，帮我..."
"根据 MIMIC-IV 技能，如何..."
"参考 MIMIC-IV 技能的模式，构建..."
```

### 查看示例
```bash
# 查看示例脚本
ls examples/

# 运行示例
python examples/quick_query_example.py
```

---

## 📊 数据库快速统计

### 核心数据
- 患者数: 364,627
- 住院数: 546,028
- ICU 住院数: 94,458
- 实验室事件: 158,478,383
- ICU 图表事件: 432,997,491

### 临床概念（预计算）
- SOFA 记录: 8,219,121
- 脓毒症病例: 41,295
- AKI 分期记录: 5,099,899

### 数据库大小
- 总大小: ~80 GB
- 最大表: chartevents (42 GB, 4.33亿行)
- 总表数: 111

---

## 🎓 推荐工作流程

### 研究项目标准流程

1. **定义研究问题**
   - 明确研究目标
   - 确定纳入/排除标准

2. **构建患者队列**
   ```python
   cohort = query_to_df("""
       SELECT ... FROM mimiciv_icu.icustays ie
       WHERE ... -- 纳入标准
   """, db='mimic')
   ```

3. **提取临床数据**
   ```python
   # 使用预计算表
   sofa = query_to_df("""
       SELECT * FROM mimiciv_derived.first_day_sofa
       WHERE stay_id IN (...)
   """, db='mimic')
   ```

4. **数据清理和验证**
   ```python
   # 检查缺失值
   print(df.isnull().sum())

   # 检查数据范围
   print(df.describe())
   ```

5. **统计分析**
   ```python
   import pandas as pd
   import matplotlib.pyplot as plt

   # 描述性统计
   # 推断性统计
   # 可视化
   ```

6. **保存结果**
   ```python
   cohort.to_csv('output/cohort.csv', index=False)
   results.to_csv('output/results.csv', index=False)
   ```

---

## 📝 版本历史

### v1.0 (2025-11-14)
- ✅ 创建 MIMIC-IV 数据提取技能
- ✅ 配置数据库连接
- ✅ 探索数据库结构
- ✅ 创建完整文档（中英文）
- ✅ 提供示例脚本和工具

---

## 🚀 下一步

### 立即可做
1. 测试数据库连接
2. 运行第一个查询
3. 探索预计算表

### 本周目标
1. 熟悉常用表和 ItemID
2. 构建第一个患者队列
3. 提取临床数据

### 本月目标
1. 完成初步数据分析
2. 生成描述性统计
3. 创建可视化图表

---

**项目状态**: ✅ 完全就绪，可以开始研究！

**最后更新**: 2025-11-14
**维护者**: Claude AI
