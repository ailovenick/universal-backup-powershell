<#
.SYNOPSIS
    Универсальный скрипт бэкапа: Robocopy, VSS (Shadow Copy), TAR и 7-Zip.
.DESCRIPTION
    Универсальный инструмент для копирования или архивации данных.
    Поддерживает:
    - Обход заблокированных файлов (Hyper-V, базы данных) через VSS.
    - Многопоточное копирование через Robocopy.
    - Архивацию через TAR или 7-Zip powershell ZIP
    - Автоматическую ротацию старых копий.
#>

# --- НАСТРОЙКИ СКРИПТА ---

# 1. ЧТО КОПИРОВАТЬ: Полный путь к файлу или папке
$SourcePath = "D:\path\to\source\file\or\folder"

# 2. КУДА СОХРАНЯТЬ: Общая папка для бэкапов
$DestDir = "D:\path\to\folder\for\bak"

# 3. МЕТОД БЭКАПА:
# 0 - БЕЗ СЖАТИЯ. Обычное копирование папок (быстро, через Robocopy).
# 1 - TAR. Встроен в Win 10/11. Нет лимита 2ГБ. Рекомендуется как стандарт. (Формат .zip)
# 2 - 7-ZIP. Максимальное сжатие. Требует установленный 7-Zip (C:\Program Files\7-Zip\7z.exe). (Формат .7z)
# 3 - СТАНДАРТ. Встроенный Zip PowerShell. 
#     ВАЖНО: В PowerShell 5.1 есть ЛИМИТ 2ГБ. В PowerShell 7+ лимит снят. (Формат .zip)
$BackupMethod = 0

# Путь к 7-Zip (нужен только для метода 2)
$Path7z = "C:\Program Files\7-Zip\7z.exe"

# 4. ИСПОЛЬЗОВАТЬ VSS (Shadow Copy)?
# $true  - Позволяет копировать файлы, занятые другими программами (Hyper-V, SQL, Outlook).
#         Решает ошибку "Процесс не может получить доступ к файлу... занят другим процессом".
# $false - Обычное копирование. Может давать ошибки на запущенных виртуальных машинах.
# ВНИМАНИЕ: Требует запуска PowerShell ОТ ИМЕНИ АДМИНИСТРАТОРА.
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
Write-Log "--- Запуск ($($MyInvocation.MyCommand.Name)). Метод: $BackupMethod, VSS: $EnableVSS ---"
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
        Write-Log "Теневая копия подключена: $vssLinkPath. Начинаю работу..."
    }

    # --- ВЫБОР МЕТОДА БЭКАПА ---
    switch ($BackupMethod) {
        0 {
            # === ОБЫЧНОЕ КОПИРОВАНИЕ (Robocopy) ===
            Write-Log "Начинаю копирование файлов..."
            if (Test-Path -Path $finalSourcePath -PathType Container) {
                $target = Join-Path -Path $currentBackupFolder -ChildPath $sourceName
                robocopy $finalSourcePath $target /E /R:3 /W:5 /MT:8 /NP
            } else {
                $srcDir = Split-Path -Path $finalSourcePath -Parent
                $srcFile = Split-Path -Path $finalSourcePath -Leaf
                robocopy $srcDir $currentBackupFolder $srcFile /R:3 /W:5 /NP
            }
            if ($LASTEXITCODE -ge 8) { throw "Ошибка Robocopy (код $LASTEXITCODE)" }
            Write-Log "Копирование успешно завершено."
        }

        1 {
            # === АРХИВАЦИЯ TAR ===
            $zipPath = Join-Path -Path $currentBackupFolder -ChildPath "$($sourceName).zip"
            Write-Log "Начинаю архивацию через TAR (без лимита 2ГБ)..."
            $parentDir = Split-Path -Path $finalSourcePath -Parent
            $leafName = Split-Path -Path $finalSourcePath -Leaf
            Push-Location $parentDir
            tar.exe -a -c -f $zipPath $leafName
            $exitCode = $LASTEXITCODE
            Pop-Location
            if ($exitCode -ne 0) { throw "Ошибка TAR (код $exitCode)" }
            Write-Log "Архив ZIP успешно создан."
        }

        2 {
            # === АРХИВАЦИЯ 7-ZIP ===
            if (-not (Test-Path $Path7z)) { throw "7-Zip не найден по пути $Path7z" }
            $zipPath = Join-Path -Path $currentBackupFolder -ChildPath "$($sourceName).7z"
            Write-Log "Начинаю архивацию через 7-Zip..."
            & $Path7z a -t7z "$zipPath" "$finalSourcePath" -mx5 -mmt8 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Ошибка 7-Zip (код $LASTEXITCODE)" }
            Write-Log "Архив 7z успешно создан."
        }

        3 {
            # === АРХИВАЦИЯ СТАНДАРТ (Internal) ===
            $zipPath = Join-Path -Path $currentBackupFolder -ChildPath "$($sourceName).zip"
            Write-Log "Начинаю стандартную архивацию (лимит 2ГБ)..."
            Compress-Archive -Path $finalSourcePath -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
            Write-Log "Архив успешно создан."
        }

        default { throw "Некорректный метод бэкапа: $BackupMethod" }
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
