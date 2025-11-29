#!/usr/bin/env python3
"""
Notion文档上传脚本
使用方法：
1. 安装依赖：pip install notion-client
2. 设置环境变量：NOTION_TOKEN 和 NOTION_DATABASE_ID
3. 运行：python upload_to_notion.py
"""

import os
import sys
from notion_client import Client
from datetime import datetime

# 配置你的Notion信息
NOTION_TOKEN = os.getenv('NOTION_TOKEN')  # 或者直接填入你的token
DATABASE_ID = os.getenv('NOTION_DATABASE_ID')  # 或者直接填入你的database_id

def read_markdown_file(filepath):
    """读取markdown文件内容"""
    with open(filepath, 'r', encoding='utf-8') as f:
        return f.read()

def convert_markdown_to_notion_blocks(markdown_text):
    """将Markdown转换为Notion blocks（简化版本）"""
    lines = markdown_text.split('\n')
    blocks = []

    for line in lines:
        if line.startswith('# '):
            # 标题1
            blocks.append({
                "object": "block",
                "type": "heading_1",
                "heading_1": {
                    "text": [{"text": {"content": line[2:]}}]
                }
            })
        elif line.startswith('## '):
            # 标题2
            blocks.append({
                "object": "block",
                "type": "heading_2",
                "heading_2": {
                    "text": [{"text": {"content": line[3:]}}]
                }
            })
        elif line.startswith('### '):
            # 标题3
            blocks.append({
                "object": "block",
                "type": "heading_3",
                "heading_3": {
                    "text": [{"text": {"content": line[4:]}}]
                }
            })
        elif line.startswith('```'):
            # 代码块 - 简化处理
            continue
        elif line.strip() == '':
            continue
        elif line.startswith('|') and line.endswith('|'):
            # 表格 - 简化为段落
            blocks.append({
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "text": [{"text": {"content": line}}]
                }
            })
        else:
            # 普通段落
            blocks.append({
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "text": [{"text": {"content": line}}]
                }
            })

    return blocks

def upload_to_notion(title, content, database_id):
    """上传到Notion"""
    if not NOTION_TOKEN:
        print("❌ 请设置NOTION_TOKEN环境变量")
        return False

    if not DATABASE_ID:
        print("❌ 请设置NOTION_DATABASE_ID环境变量")
        return False

    try:
        notion = Client(auth=NOTION_TOKEN)

        # 转换内容
        blocks = convert_markdown_to_notion_blocks(content)

        # 创建页面
        response = notion.pages.create(
            parent={"database_id": database_id},
            properties={
                "Name": {
                    "title": [{"text": {"content": title}}]
                },
                "Created": {
                    "date": {"start": datetime.now().isoformat()}
                }
            },
            children=blocks
        )

        print(f"✅ 成功上传到Notion: {response['url']}")
        return True

    except Exception as e:
        print(f"❌ 上传失败: {e}")
        return False

def main():
    # 文档文件路径
    doc_file = "/mnt/f/SaAki_Sofa_benchmark/PostgreSQL性能优化总结_SOFA2项目.md"

    if not os.path.exists(doc_file):
        print(f"❌ 文件不存在: {doc_file}")
        return

    print("📖 读取文档...")
    content = read_markdown_file(doc_file)

    print("🚀 上传到Notion...")
    success = upload_to_notion(
        title="PostgreSQL性能优化总结 - SOFA2项目",
        content=content,
        database_id=DATABASE_ID
    )

    if success:
        print("🎉 上传完成！")
    else:
        print("💡 建议手动复制上传")

if __name__ == "__main__":
    main()