# 查找PostgreSQL配置文件位置
Write-Host "查找PostgreSQL配置文件..." -ForegroundColor Green

# 方法1：查看Windows服务
$service = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($service) {
    Write-Host "`n找到PostgreSQL服务: $($service.Name)" -ForegroundColor Yellow
}

# 方法2：常见安装路径
$possiblePaths = @(
    "C:\Program Files\PostgreSQL\15\data",
    "C:\Program Files\PostgreSQL\14\data",
    "C:\Program Files\PostgreSQL\13\data",
    "C:\Program Files\PostgreSQL\16\data",
    "C:\PostgreSQL\data"
)

Write-Host "`n检查常见路径..." -ForegroundColor Green
foreach ($path in $possiblePaths) {
    if (Test-Path "$path\postgresql.conf") {
        Write-Host "✓ 找到: $path" -ForegroundColor Green
        Write-Host "  postgresql.conf: $path\postgresql.conf"
        Write-Host "  pg_hba.conf: $path\pg_hba.conf"
    }
}

Write-Host "`n如果以上都没找到，请在Windows资源管理器中搜索: postgresql.conf" -ForegroundColor Yellow
