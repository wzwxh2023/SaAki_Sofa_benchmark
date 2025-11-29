# WSL连接Windows PostgreSQL配置指南

## 第1步：找到PostgreSQL配置文件位置

### 方法A：运行PowerShell脚本（推荐）

**在Windows PowerShell中执行：**
```powershell
cd F:\SaAki_Sofa_benchmark\scripts
.\find_postgres_config.ps1
```

### 方法B：手动查找

1. 打开Windows文件资源管理器
2. 在搜索框输入：`postgresql.conf`
3. 找到文件，记住路径（通常类似：`C:\Program Files\PostgreSQL\15\data\`）

---

## 第2步：修改 `postgresql.conf`

### 2.1 用管理员权限打开文件

**路径示例**：`C:\Program Files\PostgreSQL\15\data\postgresql.conf`

**用记事本打开**（需要管理员权限）：
1. 右键记事本 → "以管理员身份运行"
2. 文件 → 打开 → 选择 `postgresql.conf`

### 2.2 找到并修改 `listen_addresses`

**按 `Ctrl+F` 搜索**：`listen_addresses`

**找到这一行**：
```conf
#listen_addresses = 'localhost'		# what IP address(es) to listen on;
```

**修改为**（删除开头的 `#` 并改为）：
```conf
listen_addresses = '*'		# what IP address(es) to listen on;
```

**保存文件**（`Ctrl+S`）

---

## 第3步：修改 `pg_hba.conf`

### 3.1 打开文件

**路径**：同目录下的 `pg_hba.conf`（例如：`C:\Program Files\PostgreSQL\15\data\pg_hba.conf`）

**同样用管理员权限的记事本打开**

### 3.2 在文件**末尾**添加以下内容

**滚动到文件最底部，添加：**

```conf
# ==============================================================================
# WSL访问规则 (由Claude Code配置)
# ==============================================================================

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# 允许WSL子网访问（推荐）
host    all             all             172.24.0.0/16           md5

# 或者更宽泛的配置（仅用于开发环境）
# host    all             all             0.0.0.0/0               md5
```

**保存文件**（`Ctrl+S`）

---

## 第4步：重启PostgreSQL服务

### 方法A：使用服务管理器（推荐）

1. 按 `Win+R` 打开运行
2. 输入：`services.msc` 回车
3. 找到服务：`postgresql-x64-15`（数字可能不同）
4. 右键 → **重新启动**

### 方法B：使用PowerShell（需要管理员权限）

**打开PowerShell（管理员）**：
```powershell
# 查看PostgreSQL服务名
Get-Service -Name "postgresql*"

# 重启服务（替换版本号）
net stop postgresql-x64-15
net start postgresql-x64-15

# 或者直接用：
Restart-Service -Name "postgresql-x64-15"
```

**看到"服务已成功启动"即可！**

---

## ✅ 检查点1：验证Windows本地连接（确保Navicat不受影响）

**在Windows PowerShell中测试：**
```powershell
# 测试本地连接
psql -U postgres -d mimiciv -c "SELECT version();"
```

**或者打开Navicat，测试连接**

✅ 如果能连接，说明配置成功且不影响本地访问！

---

## 第5步：在WSL中安装PostgreSQL客户端

**打开WSL终端（在VSCode或Windows Terminal中）**：

```bash
# 更新包列表
sudo apt update

# 安装PostgreSQL客户端
sudo apt install postgresql-client -y

# 验证安装
psql --version
```

**预期输出**：类似 `psql (PostgreSQL) 14.x`

---

## 第6步：获取Windows主机IP

**在WSL终端中运行：**

```bash
# 获取Windows主机IP
WINDOWS_HOST=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}')
echo "Windows Host IP: $WINDOWS_HOST"

# 测试能否ping通
ping -c 3 $WINDOWS_HOST
```

**记住这个IP地址**（例如：`172.24.160.1`）

---

## 第7步：测试WSL到PostgreSQL的连接

### 7.1 基础连接测试

**在WSL终端中运行：**

```bash
# 替换以下变量为您的实际值
WINDOWS_HOST="172.24.160.1"  # 上一步获取的IP
DB_USER="postgres"            # 您的PostgreSQL用户名
DB_NAME="mimiciv"            # 您的MIMIC-IV数据库名

# 测试连接
psql -h $WINDOWS_HOST -U $DB_USER -d $DB_NAME -c "SELECT current_database();"
```

**会提示输入密码，输入后如果看到：**
```
 current_database
------------------
 mimiciv
(1 row)
```

🎉 **恭喜！连接成功！**

---

## 第8步：配置Python连接

### 8.1 安装Python依赖

```bash
cd /mnt/f/SaAki_Sofa_benchmark

# 安装必要的Python包
pip install psycopg2-binary pandas sqlalchemy
```

### 8.2 修改配置文件

**编辑配置：**
```bash
nano utils/db_helper.py
```

**找到这部分并修改：**

```python
DB_CONFIG = {
    'mimic': {
        'host': WINDOWS_HOST,  # 保持不变（自动检测）
        'port': 5432,
        'database': 'mimiciv',         # 改成您的数据库名
        'user': 'postgres',            # 改成您的用户名
        'password': 'your_password'    # 改成您的密码
    },
    # ...
}
```

**按 `Ctrl+O` 保存，`Ctrl+X` 退出**

---

## 第9步：运行第一个测试查询

```bash
cd /mnt/f/SaAki_Sofa_benchmark

# 测试连接
python utils/db_helper.py
```

**如果看到：**
```
==============================================================
数据库连接测试
==============================================================
🔗 测试连接到 mimic 数据库...
   主机: 172.24.160.1
   端口: 5432
   数据库: mimiciv
✅ 连接成功！

==============================================================
MIMIC-IV ICU 表列表
==============================================================
[表格列表...]
```

🎉🎉 **完全成功！您已经可以开始分析数据了！**

---

## 🔧 故障排查

### 问题1：连接被拒绝（connection refused）

**可能原因**：PostgreSQL服务未启动或配置未生效

**解决方法**：
1. 确认PostgreSQL服务已重启
2. 检查 `postgresql.conf` 中 `listen_addresses = '*'`（前面没有#）
3. 再次重启PostgreSQL服务

### 问题2：认证失败（authentication failed）

**可能原因**：密码错误或 `pg_hba.conf` 配置不对

**解决方法**：
1. 确认密码正确
2. 检查 `pg_hba.conf` 末尾是否添加了WSL访问规则
3. 确保METHOD是 `md5` 而不是 `trust` 或 `scram-sha-256`

### 问题3：no pg_hba.conf entry

**可能原因**：`pg_hba.conf` 配置不对

**解决方法**：
1. 确认 `pg_hba.conf` 中添加了 `host all all 172.24.0.0/16 md5`
2. 确保这一行在文件中且前面没有 `#`
3. 重启PostgreSQL服务

### 问题4：Windows防火墙阻止

**解决方法**（PowerShell管理员）：
```powershell
# 添加防火墙规则
New-NetFirewallRule -DisplayName "PostgreSQL for WSL" -Direction Inbound -Protocol TCP -LocalPort 5432 -Action Allow
```

---

## 📞 需要帮助？

如果遇到任何问题，请告诉我：
1. 具体的错误信息
2. 您执行到第几步了
3. 配置文件的相关内容（可以截图或复制）

我会立即帮您解决！
