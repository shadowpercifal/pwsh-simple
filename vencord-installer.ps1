#requires -Version 5.1

# Vencord Dev Installer (Windows PowerShell 5.1)
# Simple WinForms UI to clone/download Vencord and place custom plugins.

[CmdletBinding()]
param()

# Ensure TLS 1.2 for downloads
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Test-VencordRepo {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $pkg = Join-Path $Path 'package.json'
        if (Test-Path -LiteralPath $pkg) {
            $json = Get-Content -LiteralPath $pkg -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $json -and $json.name -eq 'vencord') { return $true }
        }
    } catch {}
    return $false
}

function Clear-Directory {
    param([Parameter(Mandatory)][string]$Path)
    try {
        Write-Log "Cleaning directory: $Path"
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
        return $true
    } catch {
        Write-Log "ERROR cleaning directory '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[$timestamp] $Message"
    $txtLog.AppendText($line + [Environment]::NewLine)
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Ensure-Directory-EmptyOrCreate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$RequireEmpty
    )
    if (-not (Test-Path -LiteralPath $Path)) {
           New-Item -ItemType Directory -Path $Path -Force | Out-Null
        return $true
    }
    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($RequireEmpty -and $items.Count -gt 0) {
        return $false
    }
    return $true
}

function ConvertTo-RawGithubUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $u = [Uri]$Url
        if ($u.Host -ieq 'github.com') {
            # Format: https://github.com/<owner>/<repo>/blob/<branch>/path/to/file
            $segments = $u.AbsolutePath.Trim('/').Split('/')
            if ($segments.Length -ge 5 -and $segments[2] -ieq 'blob') {
                $owner = $segments[0]
                $repo = $segments[1]
                $branch = $segments[3]
                $filePath = ($segments[4..($segments.Length-1)] -join '/')
                return "https://raw.githubusercontent.com/$owner/$repo/$branch/$filePath"
            }
        }
    } catch {}
    return $Url
}

# Parse GitHub repository info from a URL
function Get-GitHubRepoInfo {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $u = [Uri]$Url
    } catch { return $null }
    if ($u.Host -notmatch 'github.com') { return $null }
    $path = $u.AbsolutePath.Trim('/')
    $segments = $path.Split('/')
    if ($segments.Length -lt 2) { return $null }
    $owner = $segments[0]
    $repo = ($segments[1] -replace '\.git$','')
    $branch = $null
    if ($segments.Length -ge 4 -and $segments[2] -ieq 'tree') {
        $branch = $segments[3]
    }
    return [pscustomobject]@{ Owner = $owner; Repo = $repo; Branch = $branch }
}

function Download-RepoZip {
    param(
        [Parameter(Mandatory)][string]$DestinationDir
    )
        $zipUrl = 'https://codeload.github.com/Vendicated/Vencord/zip/refs/heads/main'
    $tempZip = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "Vencord-$(Get-Random).zip")
    $tempExtract = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "Vencord-Extract-$(Get-Random)")
    try {
        Write-Log "Downloading Vencord (zip)..."
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
        Write-Log "Extracting archive..."
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
        $root = Get-ChildItem -Path $tempExtract | Where-Object { $_.PSIsContainer } | Select-Object -First 1
        if (-not $root) { throw "Could not locate extracted folder." }
        # Move content of extracted root into destination
        $rootPath = $root.FullName
        Write-Log "Moving files to destination..."
        if (-not (Test-Path -LiteralPath $DestinationDir)) { New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null }
        Get-ChildItem -Path $rootPath -Force | ForEach-Object {
            $target = Join-Path $DestinationDir $_.Name
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $_.FullName -Destination $DestinationDir -Force
        }
        Write-Log "Vencord downloaded to '$DestinationDir'."
        return $true
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        return $false
    }
    finally {
        foreach ($p in @($tempZip, $tempExtract)) {
            try { if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
        }
    }
}

function Clone-Repo {
    param(
        [Parameter(Mandatory)][string]$DestinationDir
    )
    Write-Log "Cloning Vencord with git..."
        $gitArgs = @('clone', '--depth', '1', 'https://github.com/Vendicated/Vencord.git', $DestinationDir)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ($gitArgs -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($stdout) { $stdout -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
    if ($stderr) { $stderr -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
    if ($proc.ExitCode -ne 0) {
        Write-Log "Git clone failed with exit code $($proc.ExitCode)."
        return $false
    }
    Write-Log "Vencord cloned to '$DestinationDir'."
    return $true
}

function Download-Plugins {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$PluginUrls
    )
    $pluginsDir = Join-Path $RepoRoot 'src/userplugins'
    if (-not (Test-Path -LiteralPath $pluginsDir)) { New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null }
    foreach ($url in $PluginUrls) {
        $clean = $url.Trim()
        if (-not $clean) { continue }
        try {
            # If the URL looks like a raw file or a blob link, download the single file as before
            $rawCandidate = ConvertTo-RawGithubUrl -Url $clean
            $isFile = $false
            try { $u2 = [Uri]$rawCandidate; if ($u2.Host -ieq 'raw.githubusercontent.com' -or $clean -match '/blob/') { $isFile = $true } } catch {}
            if ($isFile) {
                $fileName = [IO.Path]::GetFileName(([Uri]$rawCandidate).AbsolutePath)
                if (-not $fileName) { $fileName = "plugin-$(Get-Random).ts" }
                $outFile = Join-Path $pluginsDir $fileName
                Write-Log "Downloading plugin file: $rawCandidate"
                Invoke-WebRequest -Uri $rawCandidate -OutFile $outFile -UseBasicParsing
                Write-Log "Saved plugin to 'src/userplugins/$fileName'"
                continue
            }

            # Treat as a repository
            $info = Get-GitHubRepoInfo -Url $clean
            $repoName = $null
            $tempBase = Join-Path ([IO.Path]::GetTempPath()) ("vencord-plugin-" + (Get-Random))
            New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
            $repoRoot = $null
            $useGitHere = $false
            if ($info) { $repoName = $info.Repo }
            if (Test-CommandAvailable git) { $useGitHere = $true }

            if ($useGitHere) {
                # Clone shallow
                $cloneArgs = @('clone','--depth','1')
                if ($info -and $info.Branch) { $cloneArgs += @('-b', $info.Branch) }
                $cloneArgs += @($clean, $tempBase)
                Write-Log ("Cloning plugin repo with git: {0}" -f $clean)
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'git'
                $psi.Arguments = ($cloneArgs -join ' ')
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $stdout = $p.StandardOutput.ReadToEnd()
                $stderr = $p.StandardError.ReadToEnd()
                $p.WaitForExit()
                if ($stdout) { $stdout -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                if ($stderr) { $stderr -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                if ($p.ExitCode -ne 0) { throw "git clone failed ($($p.ExitCode))" }
                $repoRoot = $tempBase
                if (-not $repoName) {
                    try { $repoName = Split-Path -Leaf $repoRoot } catch {}
                }
            } else {
                # Download zip from GitHub
                if (-not $info) { throw "Non-GitHub repo and no Git available. Can't download: $clean" }
                $branches = @()
                if ($info.Branch) { $branches = @($info.Branch) } else { $branches = @('main','master') }
                $zipFile = Join-Path ([IO.Path]::GetTempPath()) ("$($info.Owner)-$($info.Repo)-$(Get-Random).zip")
                $exDir = Join-Path ([IO.Path]::GetTempPath()) ("extract-" + (Get-Random))
                New-Item -ItemType Directory -Path $exDir -Force | Out-Null
                $downloaded = $false
                foreach ($br in $branches) {
                    $zipUrl = "https://codeload.github.com/$($info.Owner)/$($info.Repo)/zip/refs/heads/$br"
                    try {
                        Write-Log "Downloading plugin repo zip: $zipUrl"
                        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
                        $downloaded = $true; break
                    } catch { Write-Log "Zip for branch '$br' unavailable: $($_.Exception.Message)" }
                }
                if (-not $downloaded) { throw "Could not download repo zip for any branch (tried: $($branches -join ', '))" }
                Write-Log 'Extracting plugin repo archive...'
                Expand-Archive -Path $zipFile -DestinationPath $exDir -Force
                $rootFolder = Get-ChildItem -Path $exDir -Directory | Select-Object -First 1
                if (-not $rootFolder) { throw 'Could not locate repo contents after extraction' }
                $repoRoot = $rootFolder.FullName
                try { if (Test-Path $zipFile) { Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue } } catch {}
            }

            # Decide what to copy for plugin repository behavior
            $srcPluginsRoot = Join-Path $repoRoot 'src/userplugins'
            if (Test-Path -LiteralPath $srcPluginsRoot) {
                $pluginDirs = Get-ChildItem -Path $srcPluginsRoot -Directory -ErrorAction SilentlyContinue
                if ($pluginDirs -and $pluginDirs.Count -gt 0) {
                    foreach ($pd in $pluginDirs) {
                        $name = $pd.Name
                        $dest = Join-Path $pluginsDir $name
                        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
                        Write-Log ("Copying plugin folder '{0}' from repo to '{1}'" -f $name, (Resolve-Path $pluginsDir))
                        Copy-Item -LiteralPath $pd.FullName -Destination $dest -Recurse -Force
                    }
                    # Cleanup temp
                    try { if ($useGitHere) { Remove-Item -LiteralPath (Join-Path $repoRoot '.git') -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
                    try { Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                    continue
                }
            }

            # If index.tsx sits at repo root, treat whole repo as a single plugin <repoName>
            $indexRoot = Join-Path $repoRoot 'index.tsx'
            if (Test-Path -LiteralPath $indexRoot) {
                if (-not $repoName) {
                    try { $repoName = Split-Path -Leaf $repoRoot } catch { $repoName = "repo-$(Get-Random)" }
                }
                $destRoot = Join-Path $pluginsDir $repoName
                if (Test-Path -LiteralPath $destRoot) { Remove-Item -LiteralPath $destRoot -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $destRoot -Force | Out-Null
                Write-Log ("index.tsx found at repo root; copying entire repo as plugin '{0}'." -f $repoName)
                Get-ChildItem -Path $repoRoot -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $destRoot -Recurse -Force
                }
                try { Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                continue
            }

            # No userplugins structure and no index.tsx. Offer merge overlay.
            $confirmMerge = [System.Windows.Forms.MessageBox]::Show("Plugin repo lacks 'src/userplugins' and root 'index.tsx'.\r\nMerge its contents into the main Vencord repository (overlay)?\r\nThis may overwrite existing files.", 'Merge Plugin Repo', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($confirmMerge -eq [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log 'Merging plugin repository contents into Vencord root...'
                Get-ChildItem -Path $repoRoot -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
                    $target = Join-Path $RepoRoot $_.Name
                    if (Test-Path -LiteralPath $target) {
                        # Overwrite existing
                        try { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                    }
                    Copy-Item -LiteralPath $_.FullName -Destination $RepoRoot -Recurse -Force
                }
                Write-Log 'Merge complete.'
            } else {
                Write-Log 'Merge declined; skipping this plugin repository.'
            }
            try { Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            continue
            # (Previous fallback copying entire repo into userplugins removed per new requirements)
            
        }
        catch {
            Write-Log "ERROR processing plugin URL '$clean': $($_.Exception.Message)"
        }
    }
}

function Extract-UrlsFromText {
    param([string]$Text)
    $results = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return $results }
    try {
        $regex = New-Object System.Text.RegularExpressions.Regex '(https?://\S+)', 'IgnoreCase'
        $linkMatches = $regex.Matches($Text)
        foreach ($m in $linkMatches) {
            $u = $m.Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($u)) { $results += $u }
        }
        if ($results.Count -eq 0) {
            # Fallback: split on common separators including '.git'
            $tmp = $Text -replace '(?i)(?<!^)https?://', "`n$&"
            $tmp = $tmp -replace '(?i)\.git', '.git`n'
            $results = $tmp -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
    } catch {
        $results = $Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    return $results
}

function Ensure-PortableNodeAndPnpm {
    param(
        [Parameter(Mandatory)][string]$BaseDir
    )
    $toolsDir = Join-Path $BaseDir '.tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

    $nodeOk = Test-CommandAvailable node
    if (-not $nodeOk) {
        Write-Log 'Node.js not found. Downloading portable Node.js (latest) ...'
        $latestUrl = 'https://nodejs.org/dist/latest/'
        $html = $null
        try { $html = (Invoke-WebRequest -Uri $latestUrl -UseBasicParsing).Content } catch { Write-Log "ERROR: Could not query Node.js latest listing: $($_.Exception.Message)" }
        $zipName = $null
        if ($html) {
            $m = [regex]::Match($html, 'node-v[0-9\.]+-win-x64\.zip')
            if ($m.Success) { $zipName = $m.Value }
        }
        if (-not $zipName) {
            # fallback to v20 line if listing failed
            $fallbackListing = 'https://nodejs.org/dist/latest-v20.x/'
            try {
                $fhtml = (Invoke-WebRequest -Uri $fallbackListing -UseBasicParsing).Content
                $m2 = [regex]::Match($fhtml, 'node-v[0-9\.]+-win-x64\.zip')
                if ($m2.Success) { $latestUrl = $fallbackListing; $zipName = $m2.Value }
            } catch {}
        }
        if ($zipName) {
            $zipUrl = "$latestUrl$zipName"
            $tempZip = Join-Path ([IO.Path]::GetTempPath()) $zipName
            try {
                Write-Log "Downloading $zipName ..."
                Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
                $extractDir = Join-Path $toolsDir 'node'
                if (Test-Path $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
                Write-Log 'Extracting Node.js ...'
                Expand-Archive -Path $tempZip -DestinationPath $extractDir -Force
                # The archive creates node-vX.Y.Z-win-x64 folder
                $inner = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
                if ($inner) {
                    $nodeBin = $inner.FullName
                    $env:PATH = "$nodeBin;$env:PATH"
                    Write-Log "Added Node.js to PATH (session only): $nodeBin"
                } else {
                    Write-Log 'WARNING: Could not locate extracted Node folder.'
                }
                $nodeOk = Test-CommandAvailable node
                if ($nodeOk) { Write-Log "Node version: $(node -v 2>$null)" }
            } catch {
                Write-Log "ERROR: Failed to install portable Node.js: $($_.Exception.Message)"
            } finally {
                try { if (Test-Path $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue } } catch {}
            }
        } else {
            Write-Log 'WARNING: Could not determine latest Node.zip file name.'
        }
    }

    # Ensure pnpm via corepack if possible
    $pnpmOk = Test-CommandAvailable pnpm
    if (-not $pnpmOk) {
        $corepackOk = Test-CommandAvailable corepack
        if ($corepackOk -and (Test-CommandAvailable node)) {
            try {
                Write-Log 'Enabling Corepack and preparing pnpm ...'
                & corepack enable 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } }
                & corepack prepare pnpm@latest --activate 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } }
            } catch { Write-Log "Corepack error: $($_.Exception.Message)" }
            $pnpmOk = Test-CommandAvailable pnpm
        }
        if (-not $pnpmOk) {
            # Try downloading standalone pnpm executable
            $pnpmExeUrl = 'https://github.com/pnpm/pnpm/releases/latest/download/pnpm-win-x64.exe'
            $pnpmDir = Join-Path $toolsDir 'pnpm'
            $pnpmExe = Join-Path $pnpmDir 'pnpm.exe'
            try {
                Write-Log 'Downloading standalone pnpm ...'
                if (-not (Test-Path $pnpmDir)) { New-Item -ItemType Directory -Path $pnpmDir -Force | Out-Null }
                Invoke-WebRequest -Uri $pnpmExeUrl -OutFile $pnpmExe -UseBasicParsing
                $env:PATH = "$pnpmDir;$env:PATH"
                $pnpmOk = Test-CommandAvailable pnpm
            } catch { Write-Log "ERROR: Failed to download pnpm: $($_.Exception.Message)" }
        }
    }

    return @{ Node = (Test-CommandAvailable node); Pnpm = (Test-CommandAvailable pnpm); Corepack = (Test-CommandAvailable corepack) }
}

function Run-PnpmSteps {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Install,
        [switch]$Build
    )
    Push-Location $RepoRoot
    try {
        if ($Install) {
            Write-Log 'Running: pnpm install'
            try { & pnpm install 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } } catch { Write-Log "ERROR: $($_.Exception.Message)" }
        }
        if ($Build) {
            Write-Log 'Running: pnpm build'
            try { & pnpm build 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } } catch { Write-Log "ERROR: $($_.Exception.Message)" }
            Write-Log 'Running: pnpm inject'
            try { & pnpm inject 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } } catch { Write-Log "ERROR: $($_.Exception.Message)" }
        }
    }
    finally { Pop-Location }
}

# --- UI ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Vencord Dev Installer'
$form.Size = New-Object System.Drawing.Size(780, 640)
$form.StartPosition = 'CenterScreen'
$form.MaximizeBox = $true

$lblDir = New-Object System.Windows.Forms.Label
$lblDir.Text = 'Install directory'
$lblDir.Location = New-Object System.Drawing.Point(12, 15)
$lblDir.AutoSize = $true

$txtDir = New-Object System.Windows.Forms.TextBox
$txtDir.Location = New-Object System.Drawing.Point(12, 35)
$txtDir.Size = New-Object System.Drawing.Size(620, 24)
$txtDir.Anchor = 'Top,Left,Right'

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Browse...'
$btnBrowse.Location = New-Object System.Drawing.Point(640, 33)
$btnBrowse.Size = New-Object System.Drawing.Size(110, 28)
$btnBrowse.Anchor = 'Top,Right'

$lblPlugins = New-Object System.Windows.Forms.Label
$lblPlugins.Text = 'Custom plugin URLs (one per line)'
$lblPlugins.Location = New-Object System.Drawing.Point(12, 75)
$lblPlugins.AutoSize = $true

$txtPlugins = New-Object System.Windows.Forms.TextBox
$txtPlugins.Location = New-Object System.Drawing.Point(12, 95)
$txtPlugins.Size = New-Object System.Drawing.Size(738, 130)
$txtPlugins.Multiline = $true
$txtPlugins.ScrollBars = 'Vertical'
$txtPlugins.Anchor = 'Top,Left,Right'

$chkUseGit = New-Object System.Windows.Forms.CheckBox
$chkUseGit.Text = 'Use git clone (faster, requires Git)'
$chkUseGit.Location = New-Object System.Drawing.Point(12, 235)
$chkUseGit.AutoSize = $true

$chkPnpmInstall = New-Object System.Windows.Forms.CheckBox
$chkPnpmInstall.Text = 'Run pnpm install (if pnpm is available)'
$chkPnpmInstall.Location = New-Object System.Drawing.Point(12, 260)
$chkPnpmInstall.AutoSize = $true

$chkPnpmBuild = New-Object System.Windows.Forms.CheckBox
$chkPnpmBuild.Text = 'Run pnpm build after install'
$chkPnpmBuild.Location = New-Object System.Drawing.Point(12, 285)
$chkPnpmBuild.AutoSize = $true

$chkBootstrap = New-Object System.Windows.Forms.CheckBox
$chkBootstrap.Text = 'Install portable Node.js + pnpm if missing (no admin)'
$chkBootstrap.Location = New-Object System.Drawing.Point(12, 310)
$chkBootstrap.AutoSize = $true

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Install'
$btnInstall.Location = New-Object System.Drawing.Point(12, 340)
$btnInstall.Size = New-Object System.Drawing.Size(110, 32)

$pb = New-Object System.Windows.Forms.ProgressBar
$pb.Location = New-Object System.Drawing.Point(132, 342)
$pb.Size = New-Object System.Drawing.Size(618, 28)
$pb.Style = 'Continuous'
$pb.Minimum = 0
$pb.Maximum = 100
$pb.Value = 0
$pb.Anchor = 'Top,Left,Right'

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'Log'
$lblLog.Location = New-Object System.Drawing.Point(12, 385)
$lblLog.AutoSize = $true

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 405)
$txtLog.Size = New-Object System.Drawing.Size(738, 200)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Anchor = 'Top,Left,Right,Bottom'

$form.Controls.AddRange(@($lblDir, $txtDir, $btnBrowse, $lblPlugins, $txtPlugins, $chkUseGit, $chkPnpmInstall, $chkPnpmBuild, $chkBootstrap, $btnInstall, $pb, $lblLog, $txtLog))

# Set defaults based on environment
$documents = [Environment]::GetFolderPath('MyDocuments')
$defaultDir = Join-Path $documents 'Vencord'
$txtDir.Text = $defaultDir

$hasGit = Test-CommandAvailable git
$chkUseGit.Checked = $hasGit
$chkUseGit.Enabled = $hasGit
if (-not $hasGit) { $chkUseGit.Text += ' (Git not found)' }

$hasPnpm = Test-CommandAvailable pnpm
# Keep pnpm checkboxes enabled so the user can opt-in and use the bootstrap to install tools
$chkPnpmInstall.Enabled = $true
$chkPnpmBuild.Enabled = $true
if ($hasPnpm) {
    $chkPnpmInstall.Checked = $true
} else {
    $chkPnpmInstall.Text += ' (pnpm may be installed via bootstrap)'
    $chkPnpmBuild.Text += ' (pnpm may be installed via bootstrap)'
}

# Browse handler
$btnBrowse.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = 'Select or create the Vencord install directory'
    $fbd.SelectedPath = Split-Path -Parent $txtDir.Text
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        # If user picked parent, keep suggested folder name if original ended with it
        $sel = $fbd.SelectedPath
        $current = $txtDir.Text
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            $leaf = Split-Path -Leaf $current
            $txtDir.Text = Join-Path $sel $leaf
        } else {
            $txtDir.Text = $sel
        }
    }
})

# Install handler
$btnInstall.Add_Click({
    $btnInstall.Enabled = $false
    $form.UseWaitCursor = $true
    $pb.Value = 0
    $txtLog.Clear()

    try {
        $installDir = $txtDir.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($installDir)) { [System.Windows.Forms.MessageBox]::Show('Please choose an install directory.'); return }

    $useGit = $chkUseGit.Checked -and $hasGit
    $doInstall = $chkPnpmInstall.Checked
    $doBuild = $chkPnpmBuild.Checked

        Write-Log "Install directory: $installDir"
        # Ensure directory exists
        if (-not (Test-Path -LiteralPath $installDir)) {
            try { New-Item -ItemType Directory -Path $installDir -Force | Out-Null } catch { [System.Windows.Forms.MessageBox]::Show("Cannot create the install directory."); return }
        }

        # Check if empty; if not empty, handle according to repo detection
        $existing = Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue
        $isEmpty = -not $existing -or ($existing.Count -eq 0)
        if (-not $isEmpty) {
            if (Test-VencordRepo -Path $installDir) {
                $result = [System.Windows.Forms.MessageBox]::Show("Existing Vencord installation detected.\r\n\r\nDo you want to CLEAN the folder (delete ALL contents, including .git) and reinstall?", 'Existing Vencord', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log 'User canceled cleaning.'; return }
                if (-not (Clear-Directory -Path $installDir)) { [System.Windows.Forms.MessageBox]::Show('Failed to clean directory.'); return }
                $isEmpty = $true
            } else {
                [System.Windows.Forms.MessageBox]::Show("The selected directory is not empty and does not appear to be a Vencord repo.\r\nPlease choose an empty folder or an existing Vencord folder.", 'Not Empty', 'OK', 'Warning')
                return
            }
        }

        $pb.Value = 10
        [System.Windows.Forms.Application]::DoEvents()

        $ok = $false
    if ($useGit) { $ok = Clone-Repo -DestinationDir $installDir } else { $ok = Download-RepoZip -DestinationDir $installDir }
        if (-not $ok) { throw "Failed to retrieve Vencord repository." }

        $pb.Value = 50
        [System.Windows.Forms.Application]::DoEvents()

        # Plugins
        $urls = @()
        if (-not [string]::IsNullOrWhiteSpace($txtPlugins.Text)) {
            $urls = Extract-UrlsFromText -Text $txtPlugins.Text
            if ($urls.Count -gt 0) {
                Write-Log "Detected $($urls.Count) plugin link(s)."
                Download-Plugins -RepoRoot $installDir -PluginUrls $urls
            } else {
                Write-Log 'No valid plugin URLs detected.'
            }
        } else {
            Write-Log 'No custom plugins provided.'
        }

        $pb.Value = 65
        [System.Windows.Forms.Application]::DoEvents()

        # Tools bootstrap (portable Node + pnpm) if requested
        if ($chkBootstrap.Checked) {
            Write-Log 'Checking for Node.js/pnpm and installing portable versions if needed...'
            $toolsStatus = Ensure-PortableNodeAndPnpm -BaseDir $installDir
            Write-Log ("Tools status: Node={0} pnpm={1} corepack={2}" -f $toolsStatus.Node, $toolsStatus.Pnpm, $toolsStatus.Corepack)
        }

        $pb.Value = 75
        [System.Windows.Forms.Application]::DoEvents()

        # pnpm steps (prefer pnpm, fallback to corepack pnpm)
        if ($doInstall -or $doBuild) {
            if (Test-CommandAvailable pnpm) {
                Run-PnpmSteps -RepoRoot $installDir -Install:$doInstall -Build:$doBuild
            } elseif (Test-CommandAvailable corepack) {
                Push-Location $installDir
                try {
                    if ($doInstall) { Write-Log 'Running: corepack pnpm install'; & corepack pnpm install 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                    if ($doBuild) {
                        Write-Log 'Running: corepack pnpm build'
                        & corepack pnpm build 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } }
                        Write-Log 'Running: corepack pnpm inject'
                        & corepack pnpm inject 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } }
                    }
                } catch { Write-Log "ERROR: $($_.Exception.Message)" } finally { Pop-Location }
            } else {
                Write-Log 'pnpm not found and Corepack not available; skipping pnpm steps.'
            }
        } else {
            Write-Log 'Skipping pnpm steps.'
        }

        $pb.Value = 100
        Write-Log 'Done.'
    [System.Windows.Forms.MessageBox]::Show("Vencord setup complete.`r`n`r`nRepo: $installDir`r`nPlugins folder: src/userplugins")
    }
    catch {
        Write-Log "FATAL: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("An error occurred: $($_.Exception.Message)", 'Error', 'OK', 'Error')
    }
    finally {
        $form.UseWaitCursor = $false
        $btnInstall.Enabled = $true
    }
})

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
