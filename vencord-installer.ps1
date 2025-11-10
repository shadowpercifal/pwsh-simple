#requires -Version 5.1

<#
Vencord Dev Installer v2 (Windows PowerShell 5.1)
Redesigned interactive UI requiring user-managed tool installation.
Mandatory tools: Git, Node.js, pnpm.
User can supply paths to portable versions OR rely on system-wide installation.
If path input for a tool is blank, the checker attempts system command discovery.
No automatic downloading; "Download" buttons open official pages.
#>

[CmdletBinding()] param()

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Global state ---
$script:isInstalling = $false
$script:cancelRequested = $false
$script:currentProcess = $null
$script:targetDir = $null
$script:tempPaths = New-Object System.Collections.ArrayList

function Test-CancelRequested { if ($script:cancelRequested) { throw 'CANCELLED' } }
function Test-CommandAvailable { param([string]$Name) return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue) }

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[$timestamp] $Message"
    $txtLog.AppendText($line + [Environment]::NewLine)
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# --- Tool resolution helpers ---
function Resolve-Git {
    param([string]$PathInput)
    $resolved = $false
    if ([string]::IsNullOrWhiteSpace($PathInput)) {
        $resolved = Test-CommandAvailable git
        if ($resolved) { Write-Log "Git found system-wide: $(Get-Command git).Path" }
    } else {
        if (Test-Path -LiteralPath $PathInput) {
            if ((Get-Item $PathInput).PSIsContainer) {
                $gitExe = Get-ChildItem -Path $PathInput -Recurse -Filter git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($gitExe) {
                    $rootDir = Split-Path -Parent $gitExe.FullName
                    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $rootDir })) { $env:PATH = $rootDir + ';' + $env:PATH }
                    Write-Log "Git exe found at: $($gitExe.FullName)"
                    $resolved = $true
                }
            } else {
                if ([System.IO.Path]::GetFileName($PathInput) -ieq 'git.exe') {
                    $rootDir = Split-Path -Parent $PathInput
                    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $rootDir })) { $env:PATH = $rootDir + ';' + $env:PATH }
                    Write-Log "Git exe specified: $PathInput"
                    $resolved = $true
                }
            }
        }
    }
    return $resolved
}

function Resolve-Node {
    param([string]$PathInput)
    $resolved = $false
    if ([string]::IsNullOrWhiteSpace($PathInput)) {
        $resolved = Test-CommandAvailable node
        if ($resolved) { Write-Log "Node.js found system-wide: $(Get-Command node).Path" }
    } else {
        if (Test-Path -LiteralPath $PathInput) {
            if ((Get-Item $PathInput).PSIsContainer) {
                $nodeExe = Get-ChildItem -Path $PathInput -Recurse -Filter node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($nodeExe) {
                    $dir = Split-Path -Parent $nodeExe.FullName
                    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $dir })) { $env:PATH = $dir + ';' + $env:PATH }
                    Write-Log "Node.exe found at: $($nodeExe.FullName)"
                    $resolved = $true
                }
            } else {
                if ([System.IO.Path]::GetFileName($PathInput) -ieq 'node.exe') {
                    $dir = Split-Path -Parent $PathInput
                    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $dir })) { $env:PATH = $dir + ';' + $env:PATH }
                    Write-Log "Node.exe specified: $PathInput"
                    $resolved = $true
                }
            }
        }
    }
    return $resolved
}

function Resolve-Pnpm {
    param([string]$PathInput)
    $resolved = $false
    if ([string]::IsNullOrWhiteSpace($PathInput)) {
        $resolved = Test-CommandAvailable pnpm
        if ($resolved) { Write-Log "pnpm found system-wide: $(Get-Command pnpm).Path" }
    } else {
        if (Test-Path -LiteralPath $PathInput) {
            if ((Get-Item $PathInput).PSIsContainer) {
                $pnpmExe = Get-ChildItem -Path $PathInput -Recurse -Filter pnpm.exe -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($pnpmExe) {
                    $dir = Split-Path -Parent $pnpmExe.FullName
                    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $dir })) { $env:PATH = $dir + ';' + $env:PATH }
                    Write-Log "pnpm.exe found at: $($pnpmExe.FullName)"
                    $resolved = $true
                }
            } else {
                if ([System.IO.Path]::GetFileName($PathInput) -ieq 'pnpm.exe') {
                    $dir = Split-Path -Parent $PathInput
                    if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $dir })) { $env:PATH = $dir + ';' + $env:PATH }
                    Write-Log "pnpm.exe specified: $PathInput"
                    $resolved = $true
                }
            }
        }
    }
    return $resolved
}

function Parse-PluginUrls {
    param([string]$Text)
    $results = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $results }
    try {
        $regex = New-Object System.Text.RegularExpressions.Regex '(https?://\S+)', 'IgnoreCase'
        $linkMatches = $regex.Matches($Text)
        foreach ($m in $linkMatches) { $u = $m.Value.Trim(); if ($u) { $results += $u } }
        if ($results.Count -eq 0) {
            $tmp = $Text -replace '(?i)(?<!^)https?://', "`n$&"
            $tmp = $tmp -replace '(?i)\.git', '.git`n'
            $results = $tmp -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
    } catch { $results = $Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    return $results
}

function Get-VencordRepo {
    param([string]$DestinationDir)
    Write-Log 'Cloning Vencord repository (depth=1)...'
    $gitArgs = @('clone','--depth','1','https://github.com/Vendicated/Vencord.git', $DestinationDir)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ($gitArgs -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:currentProcess = $proc
    while (-not $proc.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 200 }
    $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd(); $script:currentProcess = $null
    if ($out) { $out -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
    if ($err) { $err -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
    if ($proc.ExitCode -ne 0) { Write-Log "Git clone failed ($($proc.ExitCode))."; return $false }
    Write-Log "Vencord cloned to '$DestinationDir'."
    return $true
}

function Get-PluginRepositories {
    param([string]$RepoRoot,[string[]]$PluginUrls)
    $pluginsDir = Join-Path $RepoRoot 'src/userplugins'
    if (-not (Test-Path -LiteralPath $pluginsDir)) { New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null }
    foreach ($url in $PluginUrls) {
        $clean = $url.Trim(); if (-not $clean) { continue }
        try {
            $isFile = $false
            $rawCandidate = $clean
            try {
                $u2 = [Uri]$clean
                if ($u2.Host -ieq 'github.com' -and $u2.AbsolutePath -match '/blob/') {
                    # convert blob to raw
                    $segments = $u2.AbsolutePath.Trim('/').Split('/')
                    if ($segments.Length -ge 5 -and $segments[2] -ieq 'blob') {
                        $owner = $segments[0]; $repo = $segments[1]; $branch = $segments[3]; $fp = ($segments[4..($segments.Length-1)] -join '/')
                        $rawCandidate = "https://raw.githubusercontent.com/$owner/$repo/$branch/$fp"
                        $isFile = $true
                    }
                }
            } catch {}
            if ($clean -match 'raw.githubusercontent.com') { $isFile = $true }
            if ($isFile) {
                $fileName = [IO.Path]::GetFileName(([Uri]$rawCandidate).AbsolutePath); if (-not $fileName) { $fileName = "plugin-$(Get-Random).ts" }
                $outFile = Join-Path $pluginsDir $fileName
                Write-Log "Downloading plugin file: $rawCandidate"
                Invoke-WebRequest -Uri $rawCandidate -OutFile $outFile -UseBasicParsing
                Write-Log "Saved plugin to src/userplugins/$fileName"
                continue
            }
            # repository plugin: shallow clone then copy src/userplugins/* OR index.tsx root handling
            $info = $null
            try { $u = [Uri]$clean; if ($u.Host -match 'github.com') { $path = $u.AbsolutePath.Trim('/').Split('/'); if ($path.Length -ge 2) { $info = [pscustomobject]@{ Owner=$path[0]; Repo=($path[1] -replace '\.git$',''); Branch=$null }; if ($path.Length -ge 4 -and $path[2] -ieq 'tree') { $info.Branch = $path[3] } } } } catch {}
            $tempBase = Join-Path ([IO.Path]::GetTempPath()) ("plugin-" + (Get-Random))
            New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
            [void]$script:tempPaths.Add($tempBase)
            $cloneArgs = @('clone','--depth','1')
            if ($info -and $info.Branch) { $cloneArgs += @('-b',$info.Branch) }
            $cloneArgs += @($clean,$tempBase)
            Write-Log "Cloning plugin repo: $clean"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'git'; $psi.Arguments = ($cloneArgs -join ' ')
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi); $script:currentProcess = $p
            while (-not $p.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 200 }
            $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $script:currentProcess = $null
            if ($o) { $o -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
            if ($e) { $e -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
            if ($p.ExitCode -ne 0) { throw "git clone failed ($($p.ExitCode))" }
            $repoRoot = $tempBase
            $srcPluginsRoot = Join-Path $repoRoot 'src/userplugins'
            if (Test-Path -LiteralPath $srcPluginsRoot) {
                $pluginDirs = Get-ChildItem -Path $srcPluginsRoot -Directory -ErrorAction SilentlyContinue
                foreach ($pd in $pluginDirs) {
                    $dest = Join-Path $pluginsDir $pd.Name
                    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
                    Write-Log "Copying plugin folder: $($pd.Name)"
                    Copy-Item -LiteralPath $pd.FullName -Destination $dest -Recurse -Force
                }
                try { Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                continue
            }
            $indexRoot = Join-Path $repoRoot 'index.tsx'
            if (Test-Path -LiteralPath $indexRoot) {
                $repoName = if ($info) { $info.Repo } else { Split-Path -Leaf $repoRoot }
                $destRoot = Join-Path $pluginsDir $repoName
                if (Test-Path -LiteralPath $destRoot) { Remove-Item -LiteralPath $destRoot -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
                Write-Log "index.tsx at root; copying entire repo as plugin '$repoName'"
                Get-ChildItem -Path $repoRoot -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destRoot -Recurse -Force }
                try { Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                continue
            }
            Write-Log 'Plugin repo lacks recognizable structure; skipping (no userplugins or index.tsx).'
            try { Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        } catch { Write-Log "ERROR processing plugin URL '$clean': $($_.Exception.Message)" }
    }
}

function Invoke-PnpmSteps {
    param([string]$RepoRoot,[switch]$Install,[switch]$Build,[switch]$Inject)
    Push-Location $RepoRoot
    try {
        if ($Install) {
            Write-Log 'Running: pnpm install'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pnpm'; $psi.Arguments = 'install'
            $psi.WorkingDirectory = $RepoRoot
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi); $script:currentProcess = $p
            while (-not $p.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 250 }
            $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $script:currentProcess = $null
            if ($out) { $out -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
            if ($err) { $err -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
            if ($p.ExitCode -ne 0) { throw "pnpm install failed ($($p.ExitCode))" }
        }
        if ($Build) {
            Write-Log 'Running: pnpm build'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'pnpm'; $psi.Arguments = 'build'
            $psi.WorkingDirectory = $RepoRoot
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi); $script:currentProcess = $p
            while (-not $p.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 250 }
            $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $script:currentProcess = $null
            if ($out) { $out -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
            if ($err) { $err -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
            if ($p.ExitCode -ne 0) { throw "pnpm build failed ($($p.ExitCode))" }
        }
        if ($Inject) { Start-InjectElevatedConsole -RepoRoot $RepoRoot }
    } catch { if ($_.Exception.Message -ne 'CANCELLED') { Write-Log "ERROR: $($_.Exception.Message)" } else { throw } } finally { Pop-Location }
}

function Start-InjectElevatedConsole {
    param([string]$RepoRoot)
    try {
        $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("vencord-inject-" + (Get-Random) + ".ps1")
        # Preserve current PATH for the elevated process to ensure portable tool resolution
        $parentPath = $env:PATH
        $lines = @()
        $lines += "$ErrorActionPreference = 'Stop'"
        $lines += '$host.ui.RawUI.WindowTitle = "Vencord Inject (elevated)"'
        $lines += ('Set-Location -LiteralPath "' + ($RepoRoot.Replace('"','\"')) + '"')
        $lines += ('$env:Path = "' + ($parentPath.Replace('"','\"')) + '"')
        $lines += 'Write-Host "Working directory: $(Get-Location)"'
        $lines += 'if (Get-Command pnpm -ErrorAction SilentlyContinue) { Write-Host "Using pnpm: $(Get-Command pnpm).Path"; pnpm inject; Write-Host "Inject finished." } else { Write-Host "pnpm not found; cannot inject." }'
        $lines += 'Write-Host "Press Enter to close."'
        $lines += 'Read-Host'
        Set-Content -LiteralPath $tempScript -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
        Write-Log "Opening elevated console for 'pnpm inject'..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$tempScript`""
        $psi.WorkingDirectory = $RepoRoot; $psi.Verb = 'runas'; $psi.UseShellExecute = $true; $psi.WindowStyle = 'Normal'
        [void][System.Diagnostics.Process]::Start($psi)
        Write-Log 'Elevated console started.'
    } catch { Write-Log "ERROR launching elevated inject console: $($_.Exception.Message)" }
}

# --- UI Construction ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Vencord Dev Installer v2'
$form.Size = New-Object System.Drawing.Size(820, 720)
$form.StartPosition = 'CenterScreen'
$form.MaximizeBox = $true

$y = 12
$lblToolsHeader = New-Object System.Windows.Forms.Label; $lblToolsHeader.Text = 'Tool Status & Paths (All Mandatory)'; $lblToolsHeader.Location = New-Object System.Drawing.Point(12,$y); $lblToolsHeader.AutoSize = $true; $form.Controls.Add($lblToolsHeader); $y += 24

function New-ToolRow {
    param([string]$Name,[int]$Y)
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "${Name}:"; $lbl.Location = New-Object System.Drawing.Point(12,$Y); $lbl.AutoSize = $true
    $txt = New-Object System.Windows.Forms.TextBox; $txt.Location = New-Object System.Drawing.Point -ArgumentList 70, ($Y - 2); $txt.Size = New-Object System.Drawing.Size(360,24); $txt.Anchor = 'Top,Left,Right'
    $btnCheck = New-Object System.Windows.Forms.Button; $btnCheck.Text = 'Check'; $btnCheck.Location = New-Object System.Drawing.Point -ArgumentList 440, ($Y - 4); $btnCheck.Size = New-Object System.Drawing.Size(70,28)
    $btnDownload = New-Object System.Windows.Forms.Button; $btnDownload.Text = 'Download'; $btnDownload.Location = New-Object System.Drawing.Point -ArgumentList 520, ($Y - 4); $btnDownload.Size = New-Object System.Drawing.Size(90,28)
    $status = New-Object System.Windows.Forms.Label; $status.Text = 'Status: Unknown'; $status.Location = New-Object System.Drawing.Point(620,$Y); $status.AutoSize = $true
    return [pscustomobject]@{ Label=$lbl; TextBox=$txt; CheckButton=$btnCheck; DownloadButton=$btnDownload; StatusLabel=$status }
}

$rowGit = New-ToolRow -Name 'Git' -Y $y; $y += 32
$rowNode = New-ToolRow -Name 'Node' -Y $y; $y += 32
$rowPnpm = New-ToolRow -Name 'pnpm' -Y $y; $y += 40

$form.Controls.AddRange(@($rowGit.Label,$rowGit.TextBox,$rowGit.CheckButton,$rowGit.DownloadButton,$rowGit.StatusLabel,$rowNode.Label,$rowNode.TextBox,$rowNode.CheckButton,$rowNode.DownloadButton,$rowNode.StatusLabel,$rowPnpm.Label,$rowPnpm.TextBox,$rowPnpm.CheckButton,$rowPnpm.DownloadButton,$rowPnpm.StatusLabel))

# Vencord directory
$lblDir = New-Object System.Windows.Forms.Label; $lblDir.Text = 'Vencord install directory'; $lblDir.Location = New-Object System.Drawing.Point(12,$y); $lblDir.AutoSize = $true
$txtDir = New-Object System.Windows.Forms.TextBox; $txtDir.Location = New-Object System.Drawing.Point -ArgumentList 12, ($y + 20); $txtDir.Size = New-Object System.Drawing.Size(640,24); $txtDir.Anchor = 'Top,Left,Right'
$btnBrowse = New-Object System.Windows.Forms.Button; $btnBrowse.Text = 'Browse...'; $btnBrowse.Location = New-Object System.Drawing.Point -ArgumentList 660, ($y + 18); $btnBrowse.Size = New-Object System.Drawing.Size(120,28); $btnBrowse.Anchor = 'Top,Right'
$form.Controls.AddRange(@($lblDir,$txtDir,$btnBrowse)); $y += 60

# Plugins
$lblPlugins = New-Object System.Windows.Forms.Label; $lblPlugins.Text = 'Custom plugin URLs (one per line or separated by .git / https://)'; $lblPlugins.Location = New-Object System.Drawing.Point(12,$y); $lblPlugins.AutoSize = $true
$txtPlugins = New-Object System.Windows.Forms.TextBox; $txtPlugins.Location = New-Object System.Drawing.Point -ArgumentList 12, ($y + 20); $txtPlugins.Size = New-Object System.Drawing.Size(768,140); $txtPlugins.Multiline = $true; $txtPlugins.ScrollBars='Vertical'; $txtPlugins.Anchor='Top,Left,Right'
$form.Controls.AddRange(@($lblPlugins,$txtPlugins)); $y += 170

# pnpm step checkboxes (consecutive order enforcement)
$chkPnpmInstall = New-Object System.Windows.Forms.CheckBox; $chkPnpmInstall.Text = 'pnpm install'; $chkPnpmInstall.Location = New-Object System.Drawing.Point(12,$y); $chkPnpmInstall.AutoSize = $true; $chkPnpmInstall.Checked = $true
$chkPnpmBuild = New-Object System.Windows.Forms.CheckBox; $chkPnpmBuild.Text = 'pnpm build'; $chkPnpmBuild.Location = New-Object System.Drawing.Point(120,$y); $chkPnpmBuild.AutoSize = $true; $chkPnpmBuild.Checked = $true
$chkPnpmInject = New-Object System.Windows.Forms.CheckBox; $chkPnpmInject.Text = 'pnpm inject (elevated)'; $chkPnpmInject.Location = New-Object System.Drawing.Point(220,$y); $chkPnpmInject.AutoSize = $true; $chkPnpmInject.Checked = $true
$form.Controls.AddRange(@($chkPnpmInstall,$chkPnpmBuild,$chkPnpmInject)); $y += 40

# Action buttons
$btnInstall = New-Object System.Windows.Forms.Button; $btnInstall.Text = 'Install'; $btnInstall.Location = New-Object System.Drawing.Point(12,$y); $btnInstall.Size = New-Object System.Drawing.Size(110,34)
$btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = 'Cancel'; $btnCancel.Location = New-Object System.Drawing.Point(132,$y); $btnCancel.Size = New-Object System.Drawing.Size(110,34); $btnCancel.Enabled = $false
$form.Controls.AddRange(@($btnInstall,$btnCancel)); $y += 50

# Log output
$lblLog = New-Object System.Windows.Forms.Label; $lblLog.Text = 'Log'; $lblLog.Location = New-Object System.Drawing.Point(12,$y); $lblLog.AutoSize = $true
$txtLog = New-Object System.Windows.Forms.TextBox; $txtLog.Location = New-Object System.Drawing.Point(12,$y+20); $txtLog.Size = New-Object System.Drawing.Size(768,180); $txtLog.Multiline = $true; $txtLog.ScrollBars='Vertical'; $txtLog.ReadOnly=$true; $txtLog.Anchor='Top,Left,Right,Bottom'
$form.Controls.AddRange(@($lblLog,$txtLog))

# --- Tool status update function ---
function Update-ToolStatusLabels {
    param([bool]$Git,[bool]$Node,[bool]$Pnpm)
    $okColor = [System.Drawing.Color]::FromArgb(0,128,0)
    $badColor = [System.Drawing.Color]::FromArgb(178,34,34)
    $rowGit.StatusLabel.Text = 'Status: ' + ($(if($Git){'OK'}else{'Missing'})); $rowGit.StatusLabel.ForeColor = $(if($Git){$okColor}else{$badColor})
    $rowNode.StatusLabel.Text = 'Status: ' + ($(if($Node){'OK'}else{'Missing'})); $rowNode.StatusLabel.ForeColor = $(if($Node){$okColor}else{$badColor})
    $rowPnpm.StatusLabel.Text = 'Status: ' + ($(if($Pnpm){'OK'}else{'Missing'})); $rowPnpm.StatusLabel.ForeColor = $(if($Pnpm){$okColor}else{$badColor})
    $btnInstall.Enabled = ($Git -and $Node -and $Pnpm -and -not $script:isInstalling)
}

# --- Download button handlers ---
$rowGit.DownloadButton.Add_Click({ Write-Log 'Opening Git download page...'; Start-Process 'https://git-scm.com/download/win' })
$rowNode.DownloadButton.Add_Click({ Write-Log 'Opening Node.js download page...'; Start-Process 'https://nodejs.org/en/download' })
$rowPnpm.DownloadButton.Add_Click({ Write-Log 'Opening pnpm installation docs...'; Start-Process 'https://pnpm.io/installation' })

# --- Check button handlers ---
$rowGit.CheckButton.Add_Click({ $status = Resolve-Git -PathInput $rowGit.TextBox.Text; if($status){ Write-Log 'Git ready.' } else { Write-Log 'Git not found.' }; Update-ToolStatusLabels -Git:$status -Node:(Test-CommandAvailable node) -Pnpm:(Test-CommandAvailable pnpm) })
$rowNode.CheckButton.Add_Click({ $statusNode = Resolve-Node -PathInput $rowNode.TextBox.Text; if($statusNode){ Write-Log "Node.js ready: $(node -v 2>$null)" } else { Write-Log 'Node.js not found.' }; Update-ToolStatusLabels -Git:(Test-CommandAvailable git) -Node:$statusNode -Pnpm:(Test-CommandAvailable pnpm) })
$rowPnpm.CheckButton.Add_Click({ $statusPnpm = Resolve-Pnpm -PathInput $rowPnpm.TextBox.Text; if($statusPnpm){ Write-Log 'pnpm ready.' } else { Write-Log 'pnpm not found.' }; Update-ToolStatusLabels -Git:(Test-CommandAvailable git) -Node:(Test-CommandAvailable node) -Pnpm:$statusPnpm })

# Enforce consecutive checkbox logic
$chkPnpmInstall.Add_CheckedChanged({ if (-not $chkPnpmInstall.Checked) { $chkPnpmBuild.Checked = $false; $chkPnpmInject.Checked = $false } })
$chkPnpmBuild.Add_CheckedChanged({ if ($chkPnpmBuild.Checked -and -not $chkPnpmInstall.Checked) { $chkPnpmBuild.Checked = $false }; if (-not $chkPnpmBuild.Checked) { $chkPnpmInject.Checked = $false } })
$chkPnpmInject.Add_CheckedChanged({ if ($chkPnpmInject.Checked -and (-not $chkPnpmInstall.Checked -or -not $chkPnpmBuild.Checked)) { $chkPnpmInject.Checked = $false } })

# Browse for directory
$btnBrowse.Add_Click({ $fbd = New-Object System.Windows.Forms.FolderBrowserDialog; $fbd.Description = 'Select or create the Vencord install directory'; $fbd.SelectedPath = Split-Path -Parent $txtDir.Text; if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $sel = $fbd.SelectedPath; $leaf = 'Vencord'; $txtDir.Text = Join-Path $sel $leaf } })

# Initial defaults
$documents = [Environment]::GetFolderPath('MyDocuments'); $txtDir.Text = (Join-Path $documents 'Vencord')
Update-ToolStatusLabels -Git:(Test-CommandAvailable git) -Node:(Test-CommandAvailable node) -Pnpm:(Test-CommandAvailable pnpm)

# Cancel handler
$btnCancel.Add_Click({ if (-not $script:isInstalling) { $form.Close(); return }; $script:cancelRequested = $true; $btnCancel.Enabled = $false; Write-Log 'Cancellation requested...'; try { if ($script:currentProcess -and -not $script:currentProcess.HasExited) { $script:currentProcess.Kill() } } catch {} })

# Install handler
$btnInstall.Add_Click({
    $btnInstall.Enabled = $false; $btnCancel.Enabled = $true; $script:isInstalling = $true; $script:cancelRequested = $false
    $txtLog.Clear(); Write-Log 'Beginning installation...'
    try {
        $installDir = $txtDir.Text.Trim(); if ([string]::IsNullOrWhiteSpace($installDir)) { [System.Windows.Forms.MessageBox]::Show('Please specify install directory.'); return }
        if (-not (Test-CommandAvailable git) -or -not (Test-CommandAvailable node) -or -not (Test-CommandAvailable pnpm)) { throw 'All mandatory tools must be available before install.' }
        if (-not (Test-Path -LiteralPath $installDir)) { try { New-Item -ItemType Directory -Path $installDir -Force | Out-Null } catch { throw 'Cannot create install directory.' } }
        # If directory not empty, ask to clean
        $existing = Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue
        $isEmpty = -not $existing -or ($existing.Count -eq 0)
        if (-not $isEmpty) {
            $result = [System.Windows.Forms.MessageBox]::Show("Directory not empty. Clean (delete all) and continue?","Existing Directory",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
            if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log 'User declined cleaning.'; return }
            Write-Log 'Cleaning directory contents...'
            Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
        }
        $script:targetDir = $installDir
        Test-CancelRequested
        if (-not (Get-VencordRepo -DestinationDir $installDir)) { throw 'Failed to clone Vencord.' }
        Test-CancelRequested
        # Plugins
        $urls = Parse-PluginUrls -Text $txtPlugins.Text
        if ($urls.Count -gt 0) { Write-Log "Detected $($urls.Count) plugin link(s)."; Get-PluginRepositories -RepoRoot $installDir -PluginUrls $urls } else { Write-Log 'No plugins to process.' }
        Test-CancelRequested
        Invoke-PnpmSteps -RepoRoot $installDir -Install:$chkPnpmInstall.Checked -Build:$chkPnpmBuild.Checked -Inject:$chkPnpmInject.Checked
        Test-CancelRequested
        Write-Log 'Installation flow complete.'
        [System.Windows.Forms.MessageBox]::Show("Vencord setup complete.\n\nRepo: $installDir\nPlugins: src/userplugins","Complete")
    } catch {
        $msg = $_.Exception.Message
        if ($msg -eq 'CANCELLED') {
            Write-Log 'Cancelled. Cleaning up target directory...'
            try { if ($script:targetDir -and (Test-Path $script:targetDir)) { Remove-Item -LiteralPath $script:targetDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
            [System.Windows.Forms.MessageBox]::Show('Installation cancelled; target directory removed.','Cancelled','OK','Information')
        } else {
            Write-Log "FATAL: $msg"; [System.Windows.Forms.MessageBox]::Show("Error: $msg",'Error','OK','Error')
        }
    } finally {
        $script:isInstalling = $false; $script:currentProcess = $null; $btnCancel.Enabled = $false; Update-ToolStatusLabels -Git:(Test-CommandAvailable git) -Node:(Test-CommandAvailable node) -Pnpm:(Test-CommandAvailable pnpm)
    }
})

$form.Add_Shown({ $form.Activate() })
[void]($form.add_FormClosing({ param($src,$ev) if ($script:isInstalling -and -not $script:cancelRequested) { $script:cancelRequested = $true; try { if ($script:currentProcess -and -not $script:currentProcess.HasExited) { $script:currentProcess.Kill() } } catch {}; try { if ($script:targetDir -and (Test-Path $script:targetDir)) { Remove-Item -LiteralPath $script:targetDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}; foreach ($p in $script:tempPaths) { try { if ($p -and (Test-Path $p)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } } catch {} } } }))
[void]$form.ShowDialog()
