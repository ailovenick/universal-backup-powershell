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
# $false - создавать обычную папку с копией файлов
[bool]$EnableZip = $false

# 4. ИСПОЛЬЗОВАТЬ VSS (Shadow Copy)?
# Позволяет копировать файлы, занятые другими программами.
# ТРЕБУЕТ ЗАПУСКА ОТ ИМЕНИ АДМИНИСТРАТОРА.
[bool]$EnableVSS = $false

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
Write-Log "--- Запуск ($($MyInvocation.MyCommand.Name)). ZIP: $EnableZip, VSS: $EnableVSS ---"
$scriptHasErrors = $false

# Проверка прав администратора для VSS
if ($EnableVSS) {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "ОШИБКА: VSS требует прав администратора. Запустите консоль от имени администратора."
        exit 1
    }
}

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
$sourceDrive = [System.IO.Path]::GetPathRoot((Resolve-Path $SourcePath).Path)

# --- ШАГ 1: СОЗДАНИЕ КОПИИ ---
$timestampStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$currentBackupFolder = Join-Path -Path $DestDir -ChildPath "$($BackupFolderPrefix)$($timestampStr)"

$shadowId = $null
$vssLinkPath = $null
$finalSourcePath = $SourcePath

try {
    # Создаем папку-контейнер
    New-Item -Path $currentBackupFolder -ItemType Directory -ErrorAction Stop | Out-Null
    Write-Log "Папка копии создана: $currentBackupFolder"

    if ($EnableVSS) {
        Write-Log "Создание теневой копии (VSS) для диска $sourceDrive..."
        $wmiVss = [WMICLASS]"root\cimv2:Win32_ShadowCopy"
        $shadowResult = $wmiVss.Create($sourceDrive, "ClientAccessible")
        
        if ($shadowResult.ReturnValue -ne 0) { throw "Не удалось создать VSS (Код: $($shadowResult.ReturnValue))" }
        
        $shadowId = $shadowResult.ShadowID
        $shadowObj = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
        $shadowDevice = $shadowObj.DeviceObject + "\"
        
        # Создаем временную символьную ссылку (junction) на теневую копию
        $vssLinkPath = Join-Path -Path $env:TEMP -ChildPath "vss_link_$($timestampStr)"
        cmd /c mklink /d "$vssLinkPath" "$shadowDevice" | Out-Null
        
        if (-not (Test-Path $vssLinkPath)) { throw "Не удалось создать символьную ссылку на теневую копию" }

        # Формируем путь внутри теневой копии
        $relativePath = (Resolve-Path $SourcePath).Path.Replace($sourceDrive, "").TrimStart("\")
        $finalSourcePath = Join-Path -Path $vssLinkPath -ChildPath $relativePath
        Write-Log "Теневая копия подключена: $vssLinkPath. Начинаю копирование..."
    }

    if ($EnableZip) {
        # === АРХИВАЦИЯ ===
        $zipPath = Join-Path -Path $currentBackupFolder -ChildPath "$($sourceName).zip"
        Write-Log "Начинаю архивацию... Это может занять время."
        Compress-Archive -Path $finalSourcePath -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
        Write-Log "Архив успешно создан."
    }
    else {
        # === ОБЫЧНОЕ КОПИРОВАНИЕ ===
        Write-Log "Начинаю копирование файлов..."
        
        if (Test-Path -Path $finalSourcePath -PathType Container) {
            $target = Join-Path -Path $currentBackupFolder -ChildPath $sourceName
            robocopy $finalSourcePath $target /E /R:3 /W:5 /MT:8 /NP
        } else {
            $srcDir = Split-Path -Path $finalSourcePath -Parent
            $srcFile = Split-Path -Path $finalSourcePath -Leaf
            robocopy $srcDir $currentBackupFolder $srcFile /R:3 /W:5 /NP
        }
        
        if ($LASTEXITCODE -ge 8) { throw "Ошибка при копировании (код $LASTEXITCODE)" }
        Write-Log "Копирование успешно завершено."
    }
}
catch {
    Write-Log "КРИТИЧЕСКАЯ ОШИБКА: $($_.Exception.Message)"
    $scriptHasErrors = $true
    if (Test-Path -Path $currentBackupFolder) { 
        Remove-Item -Path $currentBackupFolder -Recurse -Force -ErrorAction SilentlyContinue 
        Write-Log "Поврежденная копия удалена."
    }
}
finally {
    # Удаляем временную ссылку
    if ($null -ne $vssLinkPath -and (Test-Path $vssLinkPath)) {
        Write-Log "Удаление временной ссылки..."
        # Удаляем именно ссылку (Directory), содержимое в теневой копии не пострадает
        if (Test-Path -Path $vssLinkPath -PathType Container) {
            cmd /c rmdir "$vssLinkPath" | Out-Null
        }
    }

    # Удаляем теневую копию
    if ($null -ne $shadowId) {
        Write-Log "Удаление теневой копии..."
        $shadowObj = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $shadowId }
        if ($shadowObj) { $shadowObj.Delete() }
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
