#!/usr/bin/env pwsh
# ============================================================================
#  跨平台基础函数库 - PowerShell兼容层 (Cross-Platform Common Library)
#  支持: Windows PowerShell 5.1+, PowerShell Core 7+ (Windows/macOS/Linux)
#  版本: 1.0.0
#  作者: gxfdev
#  仓库: https://github.com/gxfdev/shell-scripts
# ============================================================================
#  用法:
#    . .\common_lib.ps1          # 在脚本中引入
#    CommonInit                   # 初始化基础库
#    DetectOS                     # 检测操作系统
#    PkgInstall nginx             # 跨平台安装包
#    SvcStart nginx               # 跨平台启动服务
# ============================================================================

$CommonLibVersion = "1.0.0"
$Script:CommonLibLoaded = $false

if ($CommonLibLoaded) { return }

# ============================================================================
# 操作系统检测
# ============================================================================
$Script:OsType = ""
$Script:OsFamily = ""
$Script:OsDistro = ""
$Script:OsVersion = ""
$Script:OsArch = ""
$Script:IsWindows = $false
$Script:IsMacOS = $false
$Script:IsLinux = $false
$Script:IsWSL = $false
$Script:PkgManager = ""
$Script:SvcManager = ""
$Script:LogDir = ""
$Script:LogFile = ""
$Script:LogLevel = "INFO"
$Script:DryRun = $false
$Script:Verbose = $false
$Script:ErrorCount = 0
$Script:WarningCount = 0
$Script:StartTime = $null

function DetectOS {
    $Script:OsArch = $env:PROCESSOR_ARCHITECTURE
    if (-not $Script:OsArch) {
        $Script:OsArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }

    if ($IsWindows -or ($env:OS -eq "Windows_NT")) {
        $Script:IsWindows = $true
        $Script:OsType = "windows"
        $Script:OsFamily = "windows"
        $Script:OsDistro = "windows"
        $Script:OsVersion = [System.Environment]::OSVersion.Version.ToString()
        $Script:PkgManager = "choco"
        if (Get-Command scoop -ErrorAction SilentlyContinue) {
            $Script:PkgManager = "scoop"
        } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
            $Script:PkgManager = "winget"
        } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
            $Script:PkgManager = "choco"
        }
        $Script:SvcManager = "sc.exe"
        return
    }

    if ($IsMacOS) {
        $Script:IsMacOS = $true
        $Script:OsType = "macos"
        $Script:OsFamily = "darwin"
        $Script:OsDistro = "macos"
        $Script:OsVersion = (sw_vers -productVersion 2>$null) ?? "unknown"
        $Script:PkgManager = "brew"
        $Script:SvcManager = "launchctl"
        return
    }

    if ($IsLinux) {
        $Script:IsLinux = $true

        if (Test-Path /proc/version) {
            $procVersion = Get-Content /proc/version -ErrorAction SilentlyContinue
            if ($procVersion -match "microsoft") {
                $Script:IsWSL = $true
                $Script:OsType = "wsl"
            } else {
                $Script:OsType = "linux"
            }
        } else {
            $Script:OsType = "linux"
        }

        if (Test-Path /etc/os-release) {
            $osRelease = Get-Content /etc/os-release -ErrorAction SilentlyContinue
            $id = ($osRelease | Where-Object { $_ -match "^ID=" }) -replace "ID=", "" -replace '"', ""
            $versionId = ($osRelease | Where-Object { $_ -match "^VERSION_ID=" }) -replace "VERSION_ID=", "" -replace '"', ""

            $Script:OsDistro = $id
            $Script:OsVersion = $versionId

            switch ($id) {
                { $_ -match "^(centos|rhel|rocky|almalinux|ol|fedora|amzn)$" } {
                    $Script:OsFamily = "rhel"
                    $Script:PkgManager = if (Get-Command dnf -ErrorAction SilentlyContinue) { "dnf" } else { "yum" }
                    $Script:SvcManager = "systemd"
                }
                { $_ -match "^(ubuntu|debian|linuxmint|pop|elementary|kali)$" } {
                    $Script:OsFamily = "debian"
                    $Script:PkgManager = "apt"
                    $Script:SvcManager = "systemd"
                }
                "alpine" {
                    $Script:OsFamily = "alpine"
                    $Script:PkgManager = "apk"
                    $Script:SvcManager = "openrc"
                }
                { $_ -match "^(arch|manjaro|endeavouros)$" } {
                    $Script:OsFamily = "arch"
                    $Script:PkgManager = "pacman"
                    $Script:SvcManager = "systemd"
                }
                { $_ -match "^opensuse" } {
                    $Script:OsFamily = "suse"
                    $Script:PkgManager = "zypper"
                    $Script:SvcManager = "systemd"
                }
                default {
                    $idLike = ($osRelease | Where-Object { $_ -match "^ID_LIKE=" }) -replace "ID_LIKE=", "" -replace '"', ""
                    if ($idLike -match "rhel|fedora") {
                        $Script:OsFamily = "rhel"
                        $Script:PkgManager = "yum"
                    } elseif ($idLike -match "debian") {
                        $Script:OsFamily = "debian"
                        $Script:PkgManager = "apt"
                    } else {
                        $Script:OsFamily = "unknown"
                        $Script:PkgManager = "unknown"
                    }
                    $Script:SvcManager = "systemd"
                }
            }
        } else {
            $Script:OsFamily = "unknown"
            $Script:OsDistro = "unknown"
            $Script:OsVersion = "unknown"
            $Script:PkgManager = "unknown"
            $Script:SvcManager = "unknown"
        }
    }
}

# ============================================================================
# 日志系统
# ============================================================================
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("DEBUG", "INFO", "SUCCESS", "WARN", "ERROR", "FATAL", "STEP")]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [$Level] $Message"

    if ($Script:LogFile -and (Test-Path (Split-Path $Script:LogFile -Parent) -ErrorAction SilentlyContinue)) {
        Add-Content -Path $Script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }

    $colorMap = @{
        DEBUG   = "DarkGray"
        INFO    = "Cyan"
        SUCCESS = "Green"
        WARN    = "Yellow"
        ERROR   = "Red"
        FATAL   = "Red"
        STEP    = "Magenta"
    }

    $prefixMap = @{
        DEBUG   = "[DEBUG]"
        INFO    = "[INFO]"
        SUCCESS = "[OK]"
        WARN    = "[WARN]"
        ERROR   = "[FAIL]"
        FATAL   = "[FATAL]"
        STEP    = "[STEP]"
    }

    if ($Level -eq "DEBUG" -and -not $Script:Verbose) { return }

    $color = $colorMap[$Level]
    $prefix = $prefixMap[$Level]
    Write-Host -ForegroundColor $color "${prefix} $Message"

    if ($Level -eq "ERROR" -or $Level -eq "FATAL") { $Script:ErrorCount++ }
    if ($Level -eq "WARN") { $Script:WarningCount++ }
}

function LogInfo    { Write-Log -Level INFO    -Message ($args -join " ") }
function LogSuccess { Write-Log -Level SUCCESS -Message ($args -join " ") }
function LogWarn    { Write-Log -Level WARN    -Message ($args -join " ") }
function LogError   { Write-Log -Level ERROR   -Message ($args -join " ") }
function LogFatal   { Write-Log -Level FATAL   -Message ($args -join " ") }
function LogDebug   { Write-Log -Level DEBUG   -Message ($args -join " ") }
function LogStep    { Write-Log -Level STEP    -Message ($args -join " ") }

function LogSection {
    param([string]$Title)
    Write-Host ""
    Write-Host -ForegroundColor Cyan ("=" * 70)
    Write-Host -ForegroundColor Cyan "  $Title"
    Write-Host -ForegroundColor Cyan ("=" * 70)
    Write-Host ""
}

# ============================================================================
# 跨平台包管理
# ============================================================================
function PkgUpdate {
    LogInfo "更新软件包索引..."
    if ($Script:DryRun) { LogInfo "[DRY-RUN] 将更新包索引"; return }

    switch ($Script:PkgManager) {
        "apt"    { sudo apt-get update -qq }
        "yum"    { sudo yum makecache fast -q }
        "dnf"    { sudo dnf makecache --quiet }
        "apk"    { sudo apk update }
        "pacman" { sudo pacman -Sy --noconfirm }
        "zypper" { sudo zypper --non-interactive refresh }
        "brew"   { brew update }
        "choco"  { choco upgrade all -y }
        "scoop"  { scoop update }
        "winget" { winget upgrade --all }
        default  { LogError "不支持的包管理器: $($Script:PkgManager)"; return 1 }
    }
}

function PkgInstall {
    param([Parameter(Mandatory)][string[]]$Packages)

    if ($Packages.Count -eq 0) { LogError "请指定要安装的包"; return 1 }
    LogInfo "安装软件包: $($Packages -join ', ')"

    if ($Script:DryRun) { LogInfo "[DRY-RUN] 将安装: $($Packages -join ', ')"; return }

    switch ($Script:PkgManager) {
        "apt"    { sudo apt-get install -y -qq @Packages }
        "yum"    { sudo yum install -y -q @Packages }
        "dnf"    { sudo dnf install -y --quiet @Packages }
        "apk"    { sudo apk add @Packages }
        "pacman" { sudo pacman -S --noconfirm --needed @Packages }
        "zypper" { sudo zypper --non-interactive install @Packages }
        "brew"   { brew install @Packages }
        "choco"  { choco install -y @Packages }
        "scoop"  { scoop install @Packages }
        "winget" { foreach ($pkg in $Packages) { winget install -e --id $pkg } }
        default  { LogError "不支持的包管理器: $($Script:PkgManager)"; return 1 }
    }
}

function PkgRemove {
    param([Parameter(Mandatory)][string[]]$Packages)

    if ($Packages.Count -eq 0) { LogError "请指定要卸载的包"; return 1 }
    LogInfo "卸载软件包: $($Packages -join ', ')"

    if ($Script:DryRun) { LogInfo "[DRY-RUN] 将卸载: $($Packages -join ', ')"; return }

    switch ($Script:PkgManager) {
        "apt"    { sudo apt-get remove -y -qq @Packages }
        "yum"    { sudo yum remove -y -q @Packages }
        "dnf"    { sudo dnf remove -y --quiet @Packages }
        "apk"    { sudo apk del @Packages }
        "pacman" { sudo pacman -Rns --noconfirm @Packages }
        "zypper" { sudo zypper --non-interactive remove @Packages }
        "brew"   { brew uninstall @Packages }
        "choco"  { choco uninstall -y @Packages }
        "scoop"  { scoop uninstall @Packages }
        "winget" { foreach ($pkg in $Packages) { winget uninstall -e --id $pkg } }
        default  { LogError "不支持的包管理器: $($Script:PkgManager)"; return 1 }
    }
}

function PkgIsInstalled {
    param([Parameter(Mandatory)][string]$Package)

    switch ($Script:PkgManager) {
        "apt"    { dpkg -s $Package 2>$null }
        "yum"    { rpm -q $Package 2>$null }
        "dnf"    { rpm -q $Package 2>$null }
        "apk"    { apk info -e $Package 2>$null }
        "pacman" { pacman -Qi $Package 2>$null }
        "zypper" { rpm -q $Package 2>$null }
        "brew"   { brew list $Package 2>$null }
        "choco"  { choco list --local-only $Package 2>$null }
        "scoop"  { scoop list $Package 2>$null }
        "winget" { winget list -e --id $Package 2>$null }
        default  { Get-Command $Package -ErrorAction SilentlyContinue }
    }
}

# ============================================================================
# 跨平台服务管理
# ============================================================================
function SvcStart {
    param([Parameter(Mandatory)][string]$Name)
    LogInfo "启动服务: $Name"
    if ($Script:DryRun) { LogInfo "[DRY-RUN] 将启动服务: $Name"; return }

    switch ($Script:SvcManager) {
        "systemd"   { sudo systemctl start $Name }
        "openrc"    { sudo rc-service $Name start }
        "launchctl" {
            sudo launchctl load -w "/Library/LaunchDaemons/${Name}.plist" 2>$null
            if ($LASTEXITCODE -ne 0) {
                sudo launchctl kickstart -k "system/${Name}" 2>$null
                if ($LASTEXITCODE -ne 0) {
                    brew services start $Name 2>$null
                }
            }
        }
        "sc.exe"    { Start-Service -Name $Name -ErrorAction SilentlyContinue; if ($LASTEXITCODE -ne 0) { sc.exe start $Name } }
        default     { LogError "不支持的服务管理器: $($Script:SvcManager)"; return 1 }
    }
}

function SvcStop {
    param([Parameter(Mandatory)][string]$Name)
    LogInfo "停止服务: $Name"
    if ($Script:DryRun) { LogInfo "[DRY-RUN] 将停止服务: $Name"; return }

    switch ($Script:SvcManager) {
        "systemd"   { sudo systemctl stop $Name }
        "openrc"    { sudo rc-service $Name stop }
        "launchctl" {
            sudo launchctl unload -w "/Library/LaunchDaemons/${Name}.plist" 2>$null
            if ($LASTEXITCODE -ne 0) { brew services stop $Name 2>$null }
        }
        "sc.exe"    { Stop-Service -Name $Name -ErrorAction SilentlyContinue; if ($LASTEXITCODE -ne 0) { sc.exe stop $Name } }
        default     { LogError "不支持的服务管理器: $($Script:SvcManager)"; return 1 }
    }
}

function SvcRestart {
    param([Parameter(Mandatory)][string]$Name)
    LogInfo "重启服务: $Name"
    if ($Script:DryRun) { LogInfo "[DRY-RUN] 将重启服务: $Name"; return }

    switch ($Script:SvcManager) {
        "systemd"   { sudo systemctl restart $Name }
        "openrc"    { sudo rc-service $Name restart }
        "launchctl" {
            sudo launchctl unload -w "/Library/LaunchDaemons/${Name}.plist" 2>$null
            Start-Sleep -Seconds 1
            sudo launchctl load -w "/Library/LaunchDaemons/${Name}.plist" 2>$null
            if ($LASTEXITCODE -ne 0) { brew services restart $Name 2>$null }
        }
        "sc.exe"    { Restart-Service -Name $Name -ErrorAction SilentlyContinue; if ($LASTEXITCODE -ne 0) { sc.exe stop $Name; Start-Sleep -Seconds 2; sc.exe start $Name } }
        default     { LogError "不支持的服务管理器: $($Script:SvcManager)"; return 1 }
    }
}

function SvcStatus {
    param([Parameter(Mandatory)][string]$Name)

    switch ($Script:SvcManager) {
        "systemd"   { systemctl status $Name --no-pager -l }
        "openrc"    { rc-service $Name status }
        "launchctl" { sudo launchctl print "system/${Name}" 2>$null; if ($LASTEXITCODE -ne 0) { brew services list } }
        "sc.exe"    { Get-Service -Name $Name -ErrorAction SilentlyContinue | Format-List *; sc.exe query $Name }
        default     { LogError "不支持的服务管理器: $($Script:SvcManager)"; return 1 }
    }
}

function SvcEnable {
    param([Parameter(Mandatory)][string]$Name)
    LogInfo "启用服务自启动: $Name"

    switch ($Script:SvcManager) {
        "systemd"   { sudo systemctl enable $Name }
        "openrc"    { sudo rc-update add $Name default }
        "launchctl" { sudo launchctl load -w "/Library/LaunchDaemons/${Name}.plist" 2>$null }
        "sc.exe"    { Set-Service -Name $Name -StartupType Automatic; sc.exe config $Name start=auto }
        default     { LogError "不支持的服务管理器: $($Script:SvcManager)"; return 1 }
    }
}

function SvcDisable {
    param([Parameter(Mandatory)][string]$Name)
    LogInfo "禁用服务自启动: $Name"

    switch ($Script:SvcManager) {
        "systemd"   { sudo systemctl disable $Name }
        "openrc"    { sudo rc-update del $Name default }
        "launchctl" { sudo launchctl unload -w "/Library/LaunchDaemons/${Name}.plist" 2>$null }
        "sc.exe"    { Set-Service -Name $Name -StartupType Manual; sc.exe config $Name start=demand }
        default     { LogError "不支持的服务管理器: $($Script:SvcManager)"; return 1 }
    }
}

# ============================================================================
# 安全工具函数
# ============================================================================
function Get-FileHash256 {
    param([Parameter(Mandatory)][string]$Path)
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    }
    if ($Script:IsLinux -or $Script:IsMacOS) {
        return (shasum -a 256 $Path 2>$null).Split()[0]
    }
    return $null
}

function Confirm-SecurePermissions {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedOwner = "",
        [string]$MaxPermission = "644"
    )

    if (-not (Test-Path $Path)) { LogError "文件不存在: $Path"; return $false }

    if ($Script:IsLinux -or $Script:IsMacOS) {
        $perm = (stat -c "%a" $Path 2>$null) ?? "000"
        if ([int]$perm -gt [int]$MaxPermission) {
            LogWarn "文件权限过宽松: $Path ($perm > $MaxPermission)"
            return $false
        }
    }

    return $true
}

function New-RandomPassword {
    param([int]$Length = 24)

    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    $password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    return $password
}

# ============================================================================
# 网络工具函数
# ============================================================================
function Test-Connectivity {
    param(
        [Parameter(Mandatory)][string]$Host,
        [int]$Port = 0,
        [int]$TimeoutMs = 5000
    )

    if ($Port -eq 0) {
        $result = Test-Connection -ComputerName $Host -Count 1 -Quiet -ErrorAction SilentlyContinue
        return $result
    }

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcp.BeginConnect($Host, $Port, $null, $null)
        $waited = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($waited) {
            $tcp.EndConnect($asyncResult)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

function Get-PublicIP {
    try {
        $urls = @("https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com")
        foreach ($url in $urls) {
            try {
                return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content.Trim()
            } catch { continue }
        }
    } catch {}
    return "unknown"
}

# ============================================================================
# 文件系统工具
# ============================================================================
function New-BackupFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BackupDir = ""
    )

    if (-not (Test-Path $Path)) { LogError "源文件不存在: $Path"; return $null }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $fileName = Split-Path $Path -Leaf
    $backupName = "${fileName}.bak_${timestamp}"

    if ($BackupDir) {
        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
        $backupPath = Join-Path $BackupDir $backupName
    } else {
        $backupPath = "${Path}.bak_${timestamp}"
    }

    Copy-Item -Path $Path -Destination $backupPath -Force
    LogInfo "已备份: $Path -> $backupPath"
    return $backupPath
}

function Get-HumanSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return "{0:N2}GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2}MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2}KB" -f ($Bytes / 1KB) }
    return "${Bytes}B"
}

# ============================================================================
# 进程管理
# ============================================================================
function Find-ProcessByName {
    param([Parameter(Mandatory)][string]$Name)
    return Get-Process -Name $Name -ErrorAction SilentlyContinue
}

function Stop-ProcessGraceful {
    param(
        [Parameter(Mandatory)][int]$Pid,
        [int]$TimeoutSec = 30
    )

    try {
        $proc = Get-Process -Id $Pid -ErrorAction SilentlyContinue
        if (-not $proc) { return $true }

        $proc.CloseMainWindow() | Out-Null
        $proc.WaitForExit($TimeoutSec * 1000) | Out-Null

        if (-not $proc.HasExited) {
            Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue
        }

        return $true
    } catch {
        return $false
    }
}

# ============================================================================
# 配置文件解析
# ============================================================================
function Read-INIConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { LogError "配置文件不存在: $Path"; return @{} }

    $config = @{}
    $currentSection = ""

    foreach ($line in Get-Content $Path -ErrorAction SilentlyContinue) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#") -or $line.StartsWith(";")) { continue }

        if ($line -match '^\[(.+)\]$') {
            $currentSection = $Matches[1]
            if (-not $config.ContainsKey($currentSection)) { $config[$currentSection] = @{} }
            continue
        }

        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            if ($currentSection) {
                $config[$currentSection][$key] = $value
            } else {
                $config[$key] = $value
            }
        }
    }

    return $config
}

# ============================================================================
# 通知系统
# ============================================================================
function Send-Notification {
    param(
        [string]$WebhookUrl = "",
        [string]$Email = "",
        [string]$Subject = "",
        [string]$Body = "",
        [string]$Type = "webhook"
    )

    switch ($Type) {
        "webhook" {
            if (-not $WebhookUrl) { LogWarn "未配置Webhook URL"; return }
            try {
                $payload = @{ text = "$Subject`n$Body" } | ConvertTo-Json -Compress
                Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $payload -ContentType "application/json" -ErrorAction Stop
                LogInfo "Webhook通知已发送"
            } catch {
                LogError "Webhook通知发送失败: $_"
            }
        }
        "email" {
            if (-not $Email) { LogWarn "未配置邮件地址"; return }
            try {
                Send-MailMessage -To $Email -Subject $Subject -Body $Body -ErrorAction Stop
                LogInfo "邮件通知已发送"
            } catch {
                LogError "邮件通知发送失败: $_"
            }
        }
    }
}

# ============================================================================
# 锁机制
# ============================================================================
$Script:LockFiles = @{}

function Acquire-Lock {
    param(
        [string]$Name = "default",
        [int]$TimeoutSec = 300
    )

    $lockDir = if ($Script:IsWindows) { "$env:TEMP\shell-scripts-lock" } else { "/tmp/shell-scripts-lock" }
    if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }

    $lockFile = Join-Path $lockDir "${Name}.lock"

    if (Test-Path $lockFile) {
        $lockContent = Get-Content $lockFile -ErrorAction SilentlyContinue
        $lockPid = if ($lockContent) { $lockContent[0] } else { 0 }
        $lockTime = (Get-Item $lockFile).LastWriteTime
        $elapsed = (Get-Date) - $lockTime

        if ($lockPid -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
            if ($elapsed.TotalSeconds -gt $TimeoutSec) {
                LogWarn "锁文件已过期 ($([int]$elapsed.TotalSeconds)秒)，强制释放"
                Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            } else {
                LogError "另一个实例正在运行 (PID: $lockPid)，请稍后重试"
                return $false
            }
        } else {
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
        }
    }

    $PID | Out-File -FilePath $lockFile -Force
    $Script:LockFiles[$Name] = $lockFile
    LogDebug "获取锁: $lockFile"
    return $true
}

function Release-Lock {
    param([string]$Name = "default")

    if ($Script:LockFiles.ContainsKey($Name)) {
        Remove-Item $Script:LockFiles[$Name] -Force -ErrorAction SilentlyContinue
        LogDebug "释放锁: $($Script:LockFiles[$Name])"
        $Script:LockFiles.Remove($Name)
    }
}

# ============================================================================
# 初始化函数
# ============================================================================
function CommonInit {
    $Script:StartTime = Get-Date
    DetectOS

    $scriptName = Split-Path $MyInvocation.PSCommandPath -Leaf
    $scriptName = $scriptName -replace '\.ps1$', ''

    if ($Script:IsWindows) {
        $Script:LogDir = "$env:PROGRAMDATA\shell-scripts\logs\$scriptName"
    } else {
        $Script:LogDir = "/var/log/shell-scripts/$scriptName"
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $Script:LogFile = Join-Path $Script:LogDir "${scriptName}_${timestamp}.log"

    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }

    LogDebug "基础库初始化完成 (v$CommonLibVersion)"
    LogDebug "OS: $($Script:OsDistro) $($Script:OsVersion) ($($Script:OsFamily))"
    LogDebug "包管理器: $($Script:PkgManager), 服务管理器: $($Script:SvcManager)"
    LogDebug "Windows: $($Script:IsWindows), macOS: $($Script:IsMacOS), Linux: $($Script:IsLinux), WSL: $($Script:IsWSL)"
}

# ============================================================================
# 清理函数
# ============================================================================
function CommonCleanup {
    $exitCode = $LASTEXITCODE
    $elapsed = (Get-Date) - $Script:StartTime

    LogInfo "脚本执行完成，退出码: $exitCode，耗时: $([int]$elapsed.TotalSeconds)秒"
    LogInfo "错误数: $($Script:ErrorCount)，警告数: $($Script:WarningCount)"

    foreach ($lockName in $Script:LockFiles.Keys) {
        Release-Lock -Name $lockName
    }
}

$Script:CommonLibLoaded = $true
