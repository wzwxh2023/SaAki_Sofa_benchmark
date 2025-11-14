"""
数据库辅助工具 - 让Claude Code可以方便地查询数据库
类似于Navicat的功能，但更强大
"""

import pandas as pd
import psycopg2
from sqlalchemy import create_engine
from typing import Optional, Union
import subprocess

def get_windows_ip():
    """自动获取Windows主机IP"""
    # Fixed IP for this system
    return '172.19.160.1'

# 全局配置
WINDOWS_HOST = get_windows_ip()
DB_CONFIG = {
    'mimic': {
        'host': WINDOWS_HOST,
        'port': 5432,
        'database': 'mimiciv',
        'user': 'postgres',
        'password': '188211'
    },
    'eicu': {
        'host': WINDOWS_HOST,
        'port': 5432,
        'database': 'eicu',
        'user': 'postgres',
        'password': '188211'
    }
}


def query_to_df(sql: str, db: str = 'mimic', limit: Optional[int] = None) -> pd.DataFrame:
    """
    执行SQL查询并返回DataFrame（类似Navicat的查询功能）

    参数：
        sql: SQL查询语句
        db: 'mimic' 或 'eicu'
        limit: 限制返回行数（用于预览）

    返回：
        pd.DataFrame: 查询结果

    示例：
        # 查询ICU患者数量
        df = query_to_df("SELECT COUNT(*) FROM mimiciv_icu.icustays")

        # 预览前10条数据
        df = query_to_df("SELECT * FROM mimiciv_icu.icustays", limit=10)
    """
    config = DB_CONFIG[db]

    # 如果指定了limit，自动添加到SQL
    if limit and 'limit' not in sql.lower():
        sql = f"{sql.rstrip(';')} LIMIT {limit};"

    # 创建连接
    engine = create_engine(
        f"postgresql://{config['user']}:{config['password']}@"
        f"{config['host']}:{config['port']}/{config['database']}"
    )

    # 执行查询
    print(f"🔍 执行查询 (数据库: {db})...")
    df = pd.read_sql(sql, engine)
    print(f"✅ 查询完成，返回 {len(df)} 行数据")

    return df


def preview_table(table_name: str, db: str = 'mimic', n: int = 10) -> pd.DataFrame:
    """
    预览表格（类似Navicat点击表名查看数据）

    参数：
        table_name: 表名（可带schema，如 mimiciv_icu.icustays）
        db: 数据库名
        n: 预览行数

    返回：
        pd.DataFrame: 前n行数据
    """
    sql = f"SELECT * FROM {table_name} LIMIT {n}"
    return query_to_df(sql, db=db)


def get_table_info(table_name: str, db: str = 'mimic') -> pd.DataFrame:
    """
    获取表结构信息（类似Navicat的表结构查看）

    参数：
        table_name: 表名
        db: 数据库名

    返回：
        pd.DataFrame: 列名、数据类型、是否可空等信息
    """
    # 解析schema和表名
    if '.' in table_name:
        schema, table = table_name.split('.')
    else:
        schema = 'public'
        table = table_name

    sql = f"""
    SELECT
        column_name,
        data_type,
        character_maximum_length,
        is_nullable,
        column_default
    FROM information_schema.columns
    WHERE table_schema = '{schema}'
      AND table_name = '{table}'
    ORDER BY ordinal_position;
    """

    return query_to_df(sql, db=db)


def export_to_csv(sql: str, output_file: str, db: str = 'mimic',
                  chunksize: int = 10000) -> None:
    """
    导出查询结果到CSV（类似Navicat的导出功能）

    参数：
        sql: SQL查询
        output_file: 输出文件路径
        db: 数据库名
        chunksize: 分块大小（用于大数据集）

    示例：
        export_to_csv(
            "SELECT * FROM mimiciv_icu.icustays WHERE los > 7",
            "output/long_stay_patients.csv"
        )
    """
    config = DB_CONFIG[db]
    engine = create_engine(
        f"postgresql://{config['user']}:{config['password']}@"
        f"{config['host']}:{config['port']}/{config['database']}"
    )

    print(f"🔍 执行查询并导出到 {output_file}...")

    # 分块读取并写入（节省内存）
    first_chunk = True
    for chunk in pd.read_sql(sql, engine, chunksize=chunksize):
        mode = 'w' if first_chunk else 'a'
        header = first_chunk
        chunk.to_csv(output_file, mode=mode, header=header, index=False)
        first_chunk = False
        print(f"  已写入 {len(chunk)} 行...")

    print(f"✅ 导出完成！文件保存在: {output_file}")


def execute_sql_file(sql_file: str, db: str = 'mimic') -> pd.DataFrame:
    """
    执行SQL文件（类似Navicat的运行SQL脚本）

    参数：
        sql_file: SQL文件路径
        db: 数据库名

    返回：
        pd.DataFrame: 查询结果（如果是SELECT语句）
    """
    with open(sql_file, 'r', encoding='utf-8') as f:
        sql = f.read()

    return query_to_df(sql, db=db)


def get_row_count(table_name: str, db: str = 'mimic',
                  where: Optional[str] = None) -> int:
    """
    快速获取表行数

    参数：
        table_name: 表名
        db: 数据库名
        where: WHERE条件（可选）

    返回：
        int: 行数

    示例：
        # 总行数
        count = get_row_count('mimiciv_icu.icustays')

        # 带条件
        count = get_row_count('mimiciv_icu.icustays',
                             where="los > 7")
    """
    where_clause = f"WHERE {where}" if where else ""
    sql = f"SELECT COUNT(*) as count FROM {table_name} {where_clause}"
    df = query_to_df(sql, db=db)
    return int(df.iloc[0]['count'])


# =============================================================================
# 便捷函数 - 常用查询
# =============================================================================

def list_tables(schema: str = 'mimiciv_icu', db: str = 'mimic') -> pd.DataFrame:
    """列出数据库中的所有表"""
    sql = f"""
    SELECT table_name,
           pg_size_pretty(pg_total_relation_size(quote_ident(table_schema) || '.' || quote_ident(table_name))) as size
    FROM information_schema.tables
    WHERE table_schema = '{schema}'
    ORDER BY table_name;
    """
    return query_to_df(sql, db=db)


def show_sample_data(table_name: str, db: str = 'mimic', n: int = 5):
    """
    显示表的示例数据（打印到终端，便于快速查看）

    示例：
        show_sample_data('mimiciv_icu.icustays')
    """
    df = preview_table(table_name, db=db, n=n)
    print(f"\n📊 表 {table_name} 的前 {n} 行数据:\n")
    print(df.to_string())
    print(f"\n总列数: {len(df.columns)}")
    print(f"列名: {', '.join(df.columns.tolist())}")
    return df


# =============================================================================
# 测试连接
# =============================================================================

def test_connection(db: str = 'mimic') -> bool:
    """
    测试数据库连接

    返回：
        bool: 连接是否成功
    """
    try:
        config = DB_CONFIG[db]
        print(f"🔗 测试连接到 {db} 数据库...")
        print(f"   主机: {config['host']}")
        print(f"   端口: {config['port']}")
        print(f"   数据库: {config['database']}")

        conn = psycopg2.connect(
            host=config['host'],
            port=config['port'],
            database=config['database'],
            user=config['user'],
            password=config['password'],
            connect_timeout=5
        )
        conn.close()

        print(f"✅ 连接成功！")
        return True

    except Exception as e:
        print(f"❌ 连接失败: {e}")
        return False


if __name__ == '__main__':
    # 测试连接
    print("="*60)
    print("数据库连接测试")
    print("="*60)

    test_connection('mimic')
    print()

    # 显示可用的表
    print("="*60)
    print("MIMIC-IV ICU 表列表")
    print("="*60)
    tables = list_tables('mimiciv_icu')
    print(tables.to_string())
