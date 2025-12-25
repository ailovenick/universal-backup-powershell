<#
.SYNOPSIS
    Универсальный бэкап: Копирование или Архивация (ZIP).
    Позволяет выбрать уровень сжатия (Скорость vs Размер).
    Управляет ротацией старых копий.
#>

# --- НАСТРОЙКИ СКРИПТА ---

# 1. ЧТО КОПИРОВАТЬ: Полный путь к файлу или папке
$SourcePath = "D:\path\to\source\file\or\folder"

# 2. КУДА СОХРАНЯТЬ: Общая папка для бэкапов
$DestDir = "D:\path\to\folder\for\bak"

# 3. ВКЛЮЧИТЬ АРХИВАЦИЮ?
# $true  - создавать ZIP файл
# $false - создавать обычную папку с копией файлов (параметр сжатия ниже будет проигнорирован)
[bool]$EnableZip = $false

# 4. УРОВЕНЬ СЖАТИЯ (Если включена архивация):
# "Optimal"       - (Рекомендуется) Хорошее сжатие, стандартное время.
# "Fastest"       - Быстрое создание, но архив большего размера.
# "NoCompression" - Без сжатия (просто упаковка в файл .zip).
$CompressionLevel = "Optimal"

# 5. ЛИМИТ КОПИЙ: Сколько штук хранить
[int]$MaxCopies = 5

# 6. ЛОГ-ФАЙЛ (Пусто = имя скрипта.log рядом со скриптом)
$LogFile = "" 

# 7. ПРЕФИКС ПАПКИ
$BackupFolderPrefix = "backup_"

# --------------------------


# --- ПОДГОТОВКА ---
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    # Получаем имя текущего файла скрипта. Если запущен не из файла, используем дефолтное имя.
    $scriptName = if ($MyInvocation.MyCommand.Name) { $MyInvocation.MyCommand.Name } else { "Backup_Script.ps1" }
    
    # Меняем расширение (например .ps1) на .log
    $logName = [System.IO.Path]::ChangeExtension($scriptName, ".log")

    if ($PSScriptRoot) { $LogFile = Join-Path -Path $PSScriptRoot -ChildPath $logName } 
    else { $LogFile = Join-Path -Path (Get-Location) -ChildPath $logName }
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    try { Add-Content -Path $LogFile -Value $logEntry -ErrorAction Stop; Write-Host $logEntry } 
    catch { Write-Host "Ошибка лога: $_" -ForegroundColor Red }
}

# --- СТАРТ ---
Write-Log "--- Запуск ($($MyInvocation.MyCommand.Name)). Режим ZIP: $EnableZip. Уровень: $CompressionLevel ---"
$scriptHasErrors = $false

# Проверки путей
if (-not (Test-Path -Path $SourcePath)) {
    Write-Log "ОШИБКА: Источник '$SourcePath' не найден."
    exit 1
}
if (-not (Test-Path -Path $DestDir)) {
    Write-Log "Папка назначения не найдена. Создаю: '$DestDir'"
    New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
}

$sourceName = Split-Path -Path $SourcePath -Leaf

# --- ШАГ 1: СОЗДАНИЕ КОПИИ ---
$timestampStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$currentBackupFolder = Join-Path -Path $DestDir -ChildPath "$($BackupFolderPrefix)$($timestampStr)"

try {
    # Создаем папку-контейнер (например backup_2023...)
    New-Item -Path $currentBackupFolder -ItemType Directory -ErrorAction Stop | Out-Null
    Write-Log "Папка копии создана: $currentBackupFolder"

    if ($EnableZip) {
        # === АРХИВАЦИЯ ===
        $zipPath = Join-Path -Path $currentBackupFolder -ChildPath "$($sourceName).zip"
        Write-Log "Начинаю архивацию ($CompressionLevel)... Это может занять время."
        
        # Запуск команды сжатия с выбранным уровнем
        Compress-Archive -Path $SourcePath -DestinationPath $zipPath -CompressionLevel $CompressionLevel -ErrorAction Stop
        
        Write-Log "Архив успешно создан."
    }
    else {
        # === ОБЫЧНОЕ КОПИРОВАНИЕ ===
        Write-Log "Начинаю копирование файлов..."
        
        if (Test-Path -Path $SourcePath -PathType Container) {
            $target = Join-Path -Path $currentBackupFolder -ChildPath $sourceName
            # /NJH /NJS убирают лишние заголовки, оставляя только суть и прогресс
            robocopy $SourcePath $target /E /R:3 /W:5 /MT:8 /NP
        } else {
            $srcDir = Split-Path -Path $SourcePath -Parent
            if ([string]::IsNullOrEmpty($srcDir)) { $srcDir = "." }
            $srcFile = Split-Path -Path $SourcePath -Leaf
            robocopy $srcDir $currentBackupFolder $srcFile /R:3 /W:5 /NP
        }
        
        if ($LASTEXITCODE -ge 8) { throw "Ошибка при копировании (код $LASTEXITCODE)" }
        Write-Log "Копирование успешно завершено."
    }
}
catch {
    Write-Log "КРИТИЧЕСКАЯ ОШИБКА: $($_.Exception.Message)"
    $scriptHasErrors = $true
    # Чистим за собой мусор
    if (Test-Path -Path $currentBackupFolder) { 
        Remove-Item -Path $currentBackupFolder -Recurse -Force -ErrorAction SilentlyContinue 
        Write-Log "Поврежденная копия удалена."
    }
}

# --- ШАГ 2: УДАЛЕНИЕ СТАРЫХ ---
try {
    $existing = Get-ChildItem -Path $DestDir -Directory | Where-Object { $_.Name -like "$($BackupFolderPrefix)*" }
    
    if ($existing.Count -gt $MaxCopies) {
        $toDelete = $existing | Sort-Object Name | Select-Object -First ($existing.Count - $MaxCopies)
        foreach ($item in $toDelete) {
            Write-Log "Удаление старой копии: $($item.FullName)"
            Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction Stop
        }
    }
}
catch {
    Write-Log "Ошибка очистки: $($_.Exception.Message)"
    $scriptHasErrors = $true
}

if ($scriptHasErrors) { Write-Log "--- ЗАВЕРШЕНО С ОШИБКАМИ ---`n" } 
else { Write-Log "--- УСПЕШНО ЗАВЕРШЕНО ---`n" }
