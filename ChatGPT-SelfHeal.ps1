#requires -Version 5.1
<#
.SYNOPSIS
    OpenAI ChatGPT / Codex Desktop 一键自愈启动器

.DESCRIPTION
    修复 MSIX 版 ChatGPT/Codex 更新后 cua_node runtime 从 WindowsApps
    relocation 到 LocalAppData 失败的问题，然后启动应用。

    runtime-id 算法（已从 app.asar 静态分析还原）：
      runtime-id = sha256( for each of [manifest.json, bin/node.exe, bin/node_repl.exe]:
                             name + "\0" + sha256hex(file content) + "\0" ).hex[0:16]

    本脚本不硬编码任何版本号或 runtime-id，跨 OpenAI.Codex 更新自动工作。

.PARAMETER DryRun
    只做检测与报告，不停止进程、不复制、不 promote、不清理、不启动。
    用于首次安全测试。
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---- 控制台 / 日志编码（PowerShell 5.1 中文输出需要）----
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# ---- 日志目录与文件 ----
$LogDir  = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\selfheal'
try { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null } catch { }
$LogFile = Join-Path $LogDir ('selfheal-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$logEnc  = New-Object System.Text.UTF8Encoding($false)

function Write-LogLine {
    param([string]$Text)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Text"
    try { [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $logEnc) } catch { }
}
function Write-Info {
    param([string]$Text)
    Write-Host $Text
    Write-LogLine "INFO  $Text"
}
function Write-Warn {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Yellow
    Write-LogLine "WARN  $Text"
}
function Write-Err {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Red
    Write-LogLine "ERROR $Text"
}

# ---- 并发保护：命名互斥量，防止连续双击 ----
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\OpenAI.ChatGPT.SelfHeal')
    if (-not $mutex.WaitOne(0)) {
        Write-Host 'ChatGPT Self-Heal is already running.'
        exit 2
    }
} catch {
    Write-Warn "创建互斥量失败，继续运行: $($_.Exception.Message)"
}

# =====================================================================
# 工具函数
# =====================================================================

function Get-Sha256Hex {
    param([string]$Path)
    $h = Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop
    return $h.Hash.ToLowerInvariant()
}

# 首选：从 app.asar 还原的真实 runtime-id 算法
function Get-RuntimeIdFromSource {
    param([string]$SourceDir)
    $names = @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($n in $names) {
        $full = Join-Path $SourceDir ($n -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Runtime 源文件不存在: $full"
        }
        $digest = Get-Sha256Hex $full
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes($n))
        $bytes.Add([byte]0)
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes($digest))
        $bytes.Add([byte]0)
    }
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes.ToArray())
    $sha.Dispose()
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $hash) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString().Substring(0, 16)
}

# 诊断辅助：从 .staging-<runtime-id>-* 目录名解析。
# 安全策略：主流程不使用该结果作为 runtime-id，只保留函数便于人工诊断。
function Get-RuntimeIdFromStaging {
    param([string]$RuntimeRoot)
    $ids = @{}
    Get-ChildItem -LiteralPath $RuntimeRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^\.staging-([0-9a-f]{16})-.+') {
            $ids[$Matches[1]] = $true
        }
    }
    if ($ids.Count -ge 1) {
        return ($ids.Keys | Sort-Object | Select-Object -First 1)
    }
    return $null
}

# 判断 final runtime 是否完整（关键文件 size+sha256，node_modules 非空目录）
function Test-FinalRuntimeHealthy {
    param([string]$FinalDir, [string]$SourceDir)
    if (-not (Test-Path -LiteralPath $FinalDir -PathType Container)) { return $false }
    foreach ($n in @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')) {
        $src = Join-Path $SourceDir ($n -replace '/', '\')
        $dst = Join-Path $FinalDir ($n -replace '/', '\')
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $src).Length -ne (Get-Item -LiteralPath $dst).Length) { return $false }
        if ((Get-Sha256Hex $src) -ne (Get-Sha256Hex $dst)) { return $false }
    }
    $nm = Join-Path $FinalDir 'bin\node_modules'
    if (-not (Test-Path -LiteralPath $nm -PathType Container)) { return $false }
    if (@(Get-ChildItem -LiteralPath $nm -Force -ErrorAction SilentlyContinue).Count -eq 0) { return $false }
    return $true
}

# 目录内所有文件的 相对路径 -> 大小 清单
# 使用 \\?\ 前缀绕过 MAX_PATH(260) 限制，避免深路径 node_modules 漏统计
function Get-FileInventory {
    param([string]$Root)
    $Root = $Root.TrimEnd('\', '/')
    $inv = @{}
    foreach ($f in [System.IO.Directory]::EnumerateFiles(("\\?\" + $Root), '*', [System.IO.SearchOption]::AllDirectories)) {
        $clean = $f.Substring(4)
        $rel   = $clean.Substring($Root.Length).TrimStart('\', '/')
        $inv[$rel] = [System.IO.FileInfo]::new($f).Length
    }
    return $inv
}

function Compare-Inventory {
    param([hashtable]$SourceInv, [hashtable]$TargetInv)
    $missing = 0; $extra = 0; $sizeMismatch = 0
    foreach ($k in $SourceInv.Keys) {
        if (-not $TargetInv.ContainsKey($k)) { $missing++ }
        elseif ($SourceInv[$k] -ne $TargetInv[$k]) { $sizeMismatch++ }
    }
    foreach ($k in $TargetInv.Keys) {
        if (-not $SourceInv.ContainsKey($k)) { $extra++ }
    }
    return [pscustomobject]@{
        SourceCount  = $SourceInv.Count
        TargetCount  = $TargetInv.Count
        Missing      = $missing
        Extra        = $extra
        SizeMismatch = $sizeMismatch
    }
}

function Stop-AppProcesses {
    # 只结束 ChatGPT.exe 以及它当时的子进程树。
    # 不按名称全局结束 codex.exe，避免误伤用户独立运行的 Codex CLI / coding session。
    $roots = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
    if ($roots.Count -eq 0) { return }

    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    foreach ($p in $roots) {
        Write-Info "  停止 ChatGPT 进程树: PID=$($p.Id)"
        try {
            $out = & $taskkill /PID $p.Id /T /F 2>&1
            foreach ($l in $out) { Write-LogLine "  taskkill: $l" }
        } catch {
            Write-Warn "  taskkill PID=$($p.Id) 失败，将仅尝试结束该 ChatGPT 进程: $($_.Exception.Message)"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-AppViaAppx {
    param([object]$Pkg)
    $appId = $null
    try {
        $manifest = Join-Path $Pkg.InstallLocation 'AppxManifest.xml'
        [xml]$xml = Get-Content -LiteralPath $manifest -ErrorAction Stop
        $app = $xml.Package.Applications.Application | Select-Object -First 1
        if ($app) { $appId = $app.Id }
    } catch { }
    if (-not $appId) { $appId = 'App' }
    $pfn    = $Pkg.PackageFamilyName
    $launch = "shell:AppsFolder\$pfn!$appId"
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$launch`""
    return $launch
}

# =====================================================================
# 主流程
# =====================================================================

Write-Info '================ ChatGPT Self-Heal ================'
Write-Info "日志文件: $LogFile"
Write-Info "模式    : $(if ($DryRun) { 'DryRun（只检测，不修改/不启动）' } else { 'Normal' })"
Write-Info ''

try {
    # [1/6]
    Write-Info '[1/6] 检测 ChatGPT 版本'
    $pkg = @(Get-AppxPackage OpenAI.Codex -ErrorAction Stop)[0]
    if (-not $pkg) { throw '未检测到 OpenAI.Codex 应用。' }
    Write-Info "  Package : $($pkg.PackageFullName)"
    Write-Info "  Version : $($pkg.Version)"
    Write-Info "  Install : $($pkg.InstallLocation)"

    $source      = Join-Path $pkg.InstallLocation 'app\resources\cua_node'
    $runtimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "找不到 cua_node 源目录: $source"
    }

    # [2/6]
    Write-Info ''
    Write-Info '[2/6] 检测 cua_node runtime'
    $runtimeId = $null
    try {
        $runtimeId = Get-RuntimeIdFromSource $source
        Write-Info "  runtime-id : $runtimeId （由当前安装包源文件计算）"
    } catch {
        throw "无法从当前安装包可靠计算 runtime-id。为避免把新版本 runtime 提升到错误目录，脚本将安全退出，不使用旧 .staging 目录猜测。原始错误: $($_.Exception.Message)"
    }
    if ($runtimeId -notmatch '^[0-9a-f]{16}$') {
        throw "runtime-id 格式异常: $runtimeId"
    }

    $finalDir = Join-Path $runtimeRoot $runtimeId
    Write-Info "  source    : $source"
    Write-Info "  target    : $finalDir"

    $staging = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ".staging-$runtimeId-*" })
    Write-Info "  staging   : $(if ($staging.Count -gt 0) { "检测到 $($staging.Count) 个" } else { '无' })"

    $healthy = Test-FinalRuntimeHealthy $finalDir $source
    Write-Info "  runtime 完整 : $(if ($healthy) { '是' } else { '否' })"
    Write-Info "  需要修复  : $(if ($healthy) { '否' } else { '是' })"

    if ($healthy) {
        # ---- 健康路径：直接清理 staging 并启动 ----
        Write-Info ''
        Write-Info '[3/6] 修复 runtime（无需修复）'
        Write-Info '[4/6] 验证完整性（已完整）'
        Write-Info '[5/6] 清理失败的 staging（仅当前 runtime-id）'
        if (-not $DryRun) {
            $running = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
            if ($running.Count -gt 0 -and $staging.Count -gt 0) {
                Write-Warn "  ChatGPT 当前正在运行，为避免与活动进程竞争，本次不清理 staging。"
            } else {
                foreach ($d in $staging) {
                    Write-Info "  删除 $($d.Name)"
                    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        Write-Info '[6/6] 启动 ChatGPT'
        if ($DryRun) {
            Write-Info '  (DryRun) 跳过启动'
        } else {
            $launch = Start-AppViaAppx $pkg
            Write-Info "  已通过 AppX 启动: $launch"
        }
    } else {
        # ---- 修复路径 ----
        Write-Info ''
        Write-Info '[3/6] 修复 runtime'
        if ($DryRun) {
            Write-Info '  (DryRun) 跳过: 停止进程 / xcopy / promote'
        } else {
            Stop-AppProcesses

            $rand    = ([System.IO.Path]::GetRandomFileName()).Substring(0, 6)
            $tempDir = Join-Path $runtimeRoot ".repair-$runtimeId-$rand"
            New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
            Write-Info "  临时目录: $tempDir"
            New-Item -ItemType Directory -Path $tempDir | Out-Null

            $xcopy  = Join-Path $env:SystemRoot 'System32\xcopy.exe'
            $xcArgs = @($source, $tempDir, '/E', '/H', '/I', '/Y', '/G', '/Q')
            Write-Info '  正在复制 cua_node runtime（源文件为 EFS 加密，可能耗时数分钟，请勿关闭窗口）...'
            Write-Info "  执行: xcopy $($xcArgs -join ' ')"
            $xcOut  = & $xcopy @xcArgs 2>&1
            $xcExit = $LASTEXITCODE
            Write-Info "  xcopy exit code: $xcExit"
            foreach ($l in $xcOut) { Write-LogLine "  xcopy: $l" }
            if ($xcExit -ne 0) { throw "xcopy 失败, exit code=$xcExit" }

            # [4/6] 验证
            Write-Info ''
            Write-Info '[4/6] 验证完整性'
            $srcInv = Get-FileInventory $source
            $dstInv = Get-FileInventory $tempDir
            $cmp    = Compare-Inventory $srcInv $dstInv
            Write-Info "  Source files : $($cmp.SourceCount)"
            Write-Info "  Target files : $($cmp.TargetCount)"
            Write-Info "  Missing      : $($cmp.Missing)"
            Write-Info "  Extra        : $($cmp.Extra)"
            Write-Info "  Size mismatch: $($cmp.SizeMismatch)"

            $hashOk = $true
            foreach ($n in @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')) {
                $sf = Join-Path $source  ($n -replace '/', '\')
                $df = Join-Path $tempDir ($n -replace '/', '\')
                if ((Get-Sha256Hex $sf) -ne (Get-Sha256Hex $df)) {
                    $hashOk = $false
                    Write-Err "  hash 不匹配: $n"
                }
            }
            if (-not $hashOk) { throw '关键文件 hash 校验失败。' }
            if ($cmp.Missing -ne 0 -or $cmp.Extra -ne 0 -or $cmp.SizeMismatch -ne 0) {
                throw '复制验证未通过（存在 missing/extra/size 差异）。'
            }
            Write-Info '  验证通过'

            # promote: .repair-xxx -> <runtime-id>
            # 同卷 rename；若已有无效 final，会先备份，并在 promote/校验失败时自动回滚。
            Write-Info '  提升 .repair -> final'
            $backup = $null
            $failedPromote = $null
            try {
                if (Test-Path -LiteralPath $finalDir -PathType Container) {
                    $backup = Join-Path $runtimeRoot ".backup-$runtimeId-$rand"
                    Write-Warn "  已存在无效 final，重命名为备份: $backup"
                    Move-Item -LiteralPath $finalDir -Destination $backup -ErrorAction Stop
                }

                Move-Item -LiteralPath $tempDir -Destination $finalDir -ErrorAction Stop

                if (-not (Test-FinalRuntimeHealthy $finalDir $source)) {
                    throw 'promote 后 final runtime 校验失败。'
                }
                Write-Info "  promote 成功: $finalDir"
            } catch {
                $promoteError = $_
                Write-Err "  promote/校验失败，开始回滚: $($promoteError.Exception.Message)"

                # 如果新 final 已经出现但验证失败，把它移出正式路径，保留现场。
                if (Test-Path -LiteralPath $finalDir -PathType Container) {
                    $failedPromote = Join-Path $runtimeRoot ".failed-$runtimeId-$rand"
                    try {
                        Move-Item -LiteralPath $finalDir -Destination $failedPromote -ErrorAction Stop
                        Write-Warn "  未通过验证的新 final 已保留为: $failedPromote"
                    } catch {
                        Write-Err "  无法移走失败的新 final: $($_.Exception.Message)"
                    }
                }

                # 若之前存在旧 final，则尽力恢复。
                if ($backup -and (Test-Path -LiteralPath $backup -PathType Container) -and
                    -not (Test-Path -LiteralPath $finalDir)) {
                    try {
                        Move-Item -LiteralPath $backup -Destination $finalDir -ErrorAction Stop
                        Write-Warn '  已恢复原 final runtime。'
                    } catch {
                        Write-Err "  回滚原 final 失败，备份仍保留在: $backup"
                    }
                }

                throw $promoteError
            }
        }

        # [5/6] 清理
        Write-Info ''
        Write-Info '[5/6] 清理失败的 staging / repair'
        if (-not $DryRun) {
            $cleanup = Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like ".staging-$runtimeId-*" -or $_.Name -like ".repair-$runtimeId-*" }
            foreach ($d in $cleanup) {
                Write-Info "  删除 $($d.Name)"
                Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # [6/6] 启动
        Write-Info '[6/6] 启动 ChatGPT'
        if ($DryRun) {
            Write-Info '  (DryRun) 跳过启动'
        } else {
            $launch = Start-AppViaAppx $pkg
            Write-Info "  已通过 AppX 启动: $launch"
        }
    }

    Write-Info ''
    Write-Info '完成。'
    Write-LogLine 'RESULT success'
}
catch {
    Write-Err "发生错误: $($_.Exception.Message)"
    Write-LogLine "异常详情: $($_.Exception.ToString())"
    Write-LogLine 'RESULT failed'
    exit 1
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
    }
}
