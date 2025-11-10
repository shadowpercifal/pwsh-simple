#requires -Version 5.1

# Vencord Dev Installer (Windows PowerShell 5.1)
# Simple WinForms UI to clone/download Vencord and place custom plugins.

[CmdletBinding()]
param()

# Ensure TLS 1.2 for downloads
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Global state for cancellation and tracking ---
$script:isInstalling = $false
$script:cancelRequested = $false
$script:currentProcess = $null
$script:targetDir = $null
$script:tempPaths = New-Object System.Collections.ArrayList

function Test-CancelRequested {
    if ($script:cancelRequested) { throw 'CANCELLED' }
}

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

function Test-DirectoryEmptyOrCreate { # renamed from Ensure-Directory-EmptyOrCreate (unapproved verb)
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

function Get-VencordRepoZip { # renamed from Download-RepoZip
    param(
        [Parameter(Mandatory)][string]$DestinationDir
    )
        $zipUrl = 'https://codeload.github.com/Vendicated/Vencord/zip/refs/heads/main'
    $tempZip = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "Vencord-$(Get-Random).zip")
    $tempExtract = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "Vencord-Extract-$(Get-Random)")
    try {
    [void]$script:tempPaths.Add($tempZip)
    [void]$script:tempPaths.Add($tempExtract)
    Test-CancelRequested
    Write-Log "Downloading Vencord (zip)..."
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
    Test-CancelRequested
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

function Get-VencordRepoGit { # renamed from Clone-Repo
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
    $script:currentProcess = $proc
    while (-not $proc.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 200 }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $script:currentProcess = $null
    if ($stdout) { $stdout -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
    if ($stderr) { $stderr -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
    if ($proc.ExitCode -ne 0) {
        Write-Log "Git clone failed with exit code $($proc.ExitCode)."
        return $false
    }
    Write-Log "Vencord cloned to '$DestinationDir'."
    return $true
}

function Get-PluginRepositories { # renamed from Download-Plugins
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
            [void]$script:tempPaths.Add($tempBase)
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
                $script:currentProcess = $p
                while (-not $p.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 200 }
                $stdout = $p.StandardOutput.ReadToEnd()
                $stderr = $p.StandardError.ReadToEnd()
                $script:currentProcess = $null
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
                [void]$script:tempPaths.Add($zipFile)
                [void]$script:tempPaths.Add($exDir)
                $downloaded = $false
                foreach ($br in $branches) {
                    $zipUrl = "https://codeload.github.com/$($info.Owner)/$($info.Repo)/zip/refs/heads/$br"
                    try {
                        Test-CancelRequested
                        Write-Log "Downloading plugin repo zip: $zipUrl"
                        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop
                        $downloaded = $true; break
                    } catch { Write-Log "Zip for branch '$br' unavailable: $($_.Exception.Message)" }
                }
                Test-CancelRequested
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

function Get-UrlsFromText { # renamed from Extract-UrlsFromText
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

function Get-PortableNodeAndPnpm {
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

function Get-PortableGit {
    param(
        [Parameter(Mandatory)][string]$BaseDir
    )
    $toolsDir = Join-Path $BaseDir '.tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

    $gitOk = Test-CommandAvailable git
    # Always prefer installing a portable Git when bootstrap is requested to avoid inherited errors
    try {
        Write-Log 'Ensuring portable Git (MinGit) is available...'
        $latestUrl = 'https://github.com/git-for-windows/git/releases/latest'
        $html = $null
        try { $html = (Invoke-WebRequest -Uri $latestUrl -UseBasicParsing).Content } catch { Write-Log "WARNING: Could not query Git for Windows latest page: $($_.Exception.Message)" }
        $assetPath = $null
        if ($html) {
            $m = [regex]::Match($html, 'href=\"(?<u>/git-for-windows/git/releases/download/[^\"]+/MinGit-[^\"]*-64-bit\.zip)\"', 'IgnoreCase')
            if ($m.Success) { $assetPath = $m.Groups['u'].Value }
            if (-not $assetPath) {
                $m2 = [regex]::Match($html, 'href=\"(?<u>/git-for-windows/git/releases/download/[^\"]+/MinGit-[^\"]*busybox-64-bit\.zip)\"', 'IgnoreCase')
                if ($m2.Success) { $assetPath = $m2.Groups['u'].Value }
            }
        }
        if (-not $assetPath) {
            Write-Log 'WARNING: Could not determine latest MinGit zip from releases page.'
            return @{ Git = (Test-CommandAvailable git); PathAdded = $false }
        }
        $downloadUrl = 'https://github.com' + $assetPath
        $zipName = Split-Path -Leaf $downloadUrl
        $tmpZip = Join-Path ([IO.Path]::GetTempPath()) $zipName
        [void]$script:tempPaths.Add($tmpZip)
        Check-Cancel
        Write-Log ("Downloading MinGit: {0}" -f $zipName)
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tmpZip -UseBasicParsing
        Check-Cancel
        $gitDir = Join-Path $toolsDir 'git'
        if (Test-Path $gitDir) { try { Remove-Item -LiteralPath $gitDir -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
        New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
        Write-Log 'Extracting MinGit ...'
        Expand-Archive -Path $tmpZip -DestinationPath $gitDir -Force
        # Extracted folder usually contains a single root directory
        $root = Get-ChildItem -Path $gitDir -Directory | Select-Object -First 1
        $gitRoot = if ($root) { $root.FullName } else { $gitDir }
        # Prepend essential Git paths to PATH so our session uses portable Git
        $cmdPath = Join-Path $gitRoot 'cmd'
        $mingwPath = Join-Path $gitRoot 'mingw64\bin'
        $usrBin = Join-Path $gitRoot 'usr\bin'
        $pathsToAdd = @()
        if (Test-Path -LiteralPath $cmdPath) { $pathsToAdd += $cmdPath }
        if (Test-Path -LiteralPath $mingwPath) { $pathsToAdd += $mingwPath }
        if (Test-Path -LiteralPath $usrBin) { $pathsToAdd += $usrBin }
        if ($pathsToAdd.Count -gt 0) {
            $env:PATH = ([string]::Join(';', $pathsToAdd)) + ';' + $env:PATH
            Write-Log ("Added portable Git to PATH (session): {0}" -f ([string]::Join('; ', $pathsToAdd)))
        }
        $gitOk = Test-CommandAvailable git
        if ($gitOk) { Write-Log ("Git version: {0}" -f ((git --version 2>$null))) }
    } catch {
        Write-Log ("ERROR: Failed to setup portable Git: {0}" -f $_.Exception.Message)
    }
    return @{ Git = (Test-CommandAvailable git); PathAdded = $true }
}

function Invoke-PnpmSteps { # renamed from Run-PnpmSteps
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Install,
        [switch]$Build
    )
    Push-Location $RepoRoot
    try {
        if ($Install) {
            Write-Log 'Running: pnpm install'
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'pnpm'
                $psi.Arguments = 'install'
                $psi.WorkingDirectory = $RepoRoot
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $script:currentProcess = $p
                while (-not $p.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 250 }
                $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $script:currentProcess = $null
                if ($out) { $out -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                if ($err) { $err -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                if ($p.ExitCode -ne 0) { throw "pnpm install failed ($($p.ExitCode))" }
            } catch { if ($_.Exception.Message -ne 'CANCELLED') { Write-Log "ERROR: $($_.Exception.Message)" } else { throw } }
        }
        if ($Build) {
            Write-Log 'Running: pnpm build'
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = 'pnpm'
                $psi.Arguments = 'build'
                $psi.WorkingDirectory = $RepoRoot
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $script:currentProcess = $p
                while (-not $p.HasExited) { Test-CancelRequested; Start-Sleep -Milliseconds 250 }
                $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $script:currentProcess = $null
                if ($out) { $out -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                if ($err) { $err -split "`r?`n" | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                if ($p.ExitCode -ne 0) { throw "pnpm build failed ($($p.ExitCode))" }
            } catch { if ($_.Exception.Message -ne 'CANCELLED') { Write-Log "ERROR: $($_.Exception.Message)" } else { throw } }
        }
    }
    finally { Pop-Location }
}

function Start-InjectElevatedConsole {
    param([Parameter(Mandatory)][string]$RepoRoot)
    try {
        $toolsDir = Join-Path $RepoRoot '.tools'
        $pnpmExe = Join-Path $toolsDir 'pnpm/pnpm.exe'
        $nodeRoot = $null
        $nodeTools = Join-Path $toolsDir 'node'
        if (Test-Path -LiteralPath $nodeTools) {
            $inner = Get-ChildItem -Path $nodeTools -Directory | Select-Object -First 1
            if ($inner) { $nodeRoot = $inner.FullName }
        }

        $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("vencord-inject-" + (Get-Random) + ".ps1")
        $lines = @()
        # Use single-quoted outer strings to prevent premature interpolation of $ in this parent script.
        $lines += "$ErrorActionPreference = 'Stop'"
        $lines += '$host.ui.RawUI.WindowTitle = "Vencord Inject (elevated)"'
        $lines += ('Set-Location -LiteralPath "' + ($RepoRoot.Replace('"','\"')) + '"')
        if ($nodeRoot) { $lines += ('$env:Path = "' + ($nodeRoot.Replace('"','\"')) + ';" + $env:Path') }
        $lines += 'Write-Host "Working directory: $(Get-Location)"'
        $lines += 'Write-Host "Attempting to locate pnpm..."'
        $lines += ('if (Test-Path -LiteralPath "' + ($pnpmExe.Replace('"','\"')) + '") { Write-Host "Using portable pnpm.exe"; & "' + ($pnpmExe.Replace('"','\"')) + '" inject; Write-Host "Inject finished."; goto :done }')
        $lines += 'if (Get-Command pnpm -ErrorAction SilentlyContinue) { Write-Host "Using pnpm from PATH: $(Get-Command pnpm).Path"; pnpm inject; Write-Host "Inject finished."; goto :done }'
        $lines += ':corepack'
        $lines += 'if (Get-Command corepack -ErrorAction SilentlyContinue) {'
        $lines += '  Write-Host "Corepack found. Enabling and preparing pnpm..."'
        $lines += '  try { corepack enable } catch { Write-Host "corepack enable error: $($_.Exception.Message)" }'
        $lines += '  try { corepack prepare pnpm@latest --activate } catch { Write-Host "corepack prepare error: $($_.Exception.Message)" }'
        $lines += '  if (Get-Command pnpm -ErrorAction SilentlyContinue) { Write-Host "Using pnpm from Corepack: $(Get-Command pnpm).Path"; pnpm inject; Write-Host "Inject finished."; goto :done }'
        $lines += '}'
        $lines += 'Write-Host "pnpm not found; cannot inject."'
        $lines += ':done'
        $lines += 'Write-Host "Injection script complete."'
        $lines += 'Write-Host "Press Enter to close this window."'
        $lines += 'Read-Host'
        Set-Content -LiteralPath $tempScript -Value ($lines -join [Environment]::NewLine) -Encoding UTF8

        Write-Log "Opening elevated console for 'pnpm inject'..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$tempScript`""
        $psi.WorkingDirectory = $RepoRoot
        $psi.Verb = 'runas'
        $psi.UseShellExecute = $true
        $psi.WindowStyle = 'Normal'
        [void][System.Diagnostics.Process]::Start($psi)
        Write-Log 'Elevated console started. Follow prompts in the new window to complete injection.'
    }
    catch {
        Write-Log "ERROR launching elevated inject console: $($_.Exception.Message)"
    }
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
$lblPlugins.Location = New-Object System.Drawing.Point(12, 95)
$lblPlugins.AutoSize = $true

$txtPlugins = New-Object System.Windows.Forms.TextBox
$txtPlugins.Location = New-Object System.Drawing.Point(12, 115)
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

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(132, 340)
$btnCancel.Size = New-Object System.Drawing.Size(110, 32)
$btnCancel.Enabled = $false

$pb = New-Object System.Windows.Forms.ProgressBar
$pb.Location = New-Object System.Drawing.Point(252, 342)
$pb.Size = New-Object System.Drawing.Size(498, 28)
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

# Tool status labels
$lblTools = New-Object System.Windows.Forms.Label
$lblTools.Text = 'Tools:'
$lblTools.Location = New-Object System.Drawing.Point(12, 75)
$lblTools.AutoSize = $true

$lblGitStatus = New-Object System.Windows.Forms.Label
$lblGitStatus.Location = New-Object System.Drawing.Point(70, 75)
$lblGitStatus.AutoSize = $true

$lblNodeStatus = New-Object System.Windows.Forms.Label
$lblNodeStatus.Location = New-Object System.Drawing.Point(200, 75)
$lblNodeStatus.AutoSize = $true

$lblPnpmStatus = New-Object System.Windows.Forms.Label
$lblPnpmStatus.Location = New-Object System.Drawing.Point(340, 75)
$lblPnpmStatus.AutoSize = $true

function Update-ToolStatus {
    param([bool]$Git, [bool]$Node, [bool]$Pnpm)
    $lblGitStatus.Text = 'Git: ' + ($(if($Git){'Found'}else{'Missing'}))
    $lblNodeStatus.Text = 'Node: ' + ($(if($Node){'Found'}else{'Missing'}))
    $lblPnpmStatus.Text = 'pnpm: ' + ($(if($Pnpm){'Found'}else{'Missing'}))
    $ok = [System.Drawing.Color]::FromArgb(0,128,0)
    $bad = [System.Drawing.Color]::FromArgb(178,34,34)
    $lblGitStatus.ForeColor = $(if($Git){$ok}else{$bad})
    $lblNodeStatus.ForeColor = $(if($Node){$ok}else{$bad})
    $lblPnpmStatus.ForeColor = $(if($Pnpm){$ok}else{$bad})
}

$form.Controls.AddRange(@($lblDir, $txtDir, $btnBrowse, $lblTools, $lblGitStatus, $lblNodeStatus, $lblPnpmStatus, $lblPlugins, $txtPlugins, $chkUseGit, $chkPnpmInstall, $chkPnpmBuild, $chkBootstrap, $btnInstall, $btnCancel, $pb, $lblLog, $txtLog))

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

# Initial tool status display
Update-ToolStatus -Git:$hasGit -Node:(Test-CommandAvailable node) -Pnpm:(Test-CommandAvailable pnpm)

# Cancel handler
$btnCancel.Add_Click({
    if (-not $script:isInstalling) { $form.Close(); return }
    $script:cancelRequested = $true
    $btnCancel.Enabled = $false
    Write-Log 'Cancellation requested...'
    try { if ($script:currentProcess -and -not $script:currentProcess.HasExited) { $script:currentProcess.Kill() } } catch {}
})

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
        $script:isInstalling = $true
        $script:cancelRequested = $false
        $btnCancel.Enabled = $true
        $installDir = $txtDir.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($installDir)) { [System.Windows.Forms.MessageBox]::Show('Please choose an install directory.'); return }

    $useGit = $chkUseGit.Checked -and $hasGit
    $doInstall = $chkPnpmInstall.Checked
    $doBuild = $chkPnpmBuild.Checked

        Write-Log "Install directory: $installDir"
        $script:targetDir = $installDir
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

    Check-Cancel
    $pb.Value = 10
        [System.Windows.Forms.Application]::DoEvents()

    $ok = $false
    if ($useGit) { $ok = Get-VencordRepoGit -DestinationDir $installDir } else { $ok = Get-VencordRepoZip -DestinationDir $installDir }
        if (-not $ok) { throw "Failed to retrieve Vencord repository." }

    Check-Cancel
    $pb.Value = 50
        [System.Windows.Forms.Application]::DoEvents()

        # Plugins
        $urls = @()
        if (-not [string]::IsNullOrWhiteSpace($txtPlugins.Text)) {
            $urls = Get-UrlsFromText -Text $txtPlugins.Text
            if ($urls.Count -gt 0) {
                Write-Log "Detected $($urls.Count) plugin link(s)."
                Get-PluginRepositories -RepoRoot $installDir -PluginUrls $urls
            } else {
                Write-Log 'No valid plugin URLs detected.'
            }
        } else {
            Write-Log 'No custom plugins provided.'
        }

    Check-Cancel
    $pb.Value = 65
        [System.Windows.Forms.Application]::DoEvents()

        # Tools bootstrap (portable Node + pnpm) if requested
        if ($chkBootstrap.Checked) {
            Write-Log 'Checking for Node.js/pnpm and installing portable versions if needed...'
            $gitPortable = Get-PortableGit -BaseDir $installDir
            $toolsStatus = Get-PortableNodeAndPnpm -BaseDir $installDir
            Write-Log ("Tools status: Node={0} pnpm={1} corepack={2}" -f $toolsStatus.Node, $toolsStatus.Pnpm, $toolsStatus.Corepack)
            if ($gitPortable.Git) { Write-Log 'Portable Git ready.' } else { Write-Log 'Portable Git not available.' }
            $hasGit = Test-CommandAvailable git
            Update-ToolStatus -Git:$hasGit -Node:(Test-CommandAvailable node) -Pnpm:(Test-CommandAvailable pnpm)
        }

    Check-Cancel
    $pb.Value = 75
        [System.Windows.Forms.Application]::DoEvents()

        # pnpm steps (prefer pnpm, fallback to corepack pnpm)
        if ($doInstall -or $doBuild) {
            if (Test-CommandAvailable pnpm) {
                Invoke-PnpmSteps -RepoRoot $installDir -Install:$doInstall -Build:$doBuild
                if ($doBuild) { Start-InjectElevatedConsole -RepoRoot $installDir }
            } elseif (Test-CommandAvailable corepack) {
                Push-Location $installDir
                try {
                    if ($doInstall) { Write-Log 'Running: corepack pnpm install'; & corepack pnpm install 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } } }
                    if ($doBuild) {
                        Write-Log 'Running: corepack pnpm build'
                        & corepack pnpm build 2>&1 | ForEach-Object { if ($_ -ne '') { Write-Log $_ } }
                        Start-InjectElevatedConsole -RepoRoot $installDir
                    }
                } catch { Write-Log "ERROR: $($_.Exception.Message)" } finally { Pop-Location }
            } else {
                Write-Log 'pnpm not found and Corepack not available; skipping pnpm steps.'
            }
        } else {
            Write-Log 'Skipping pnpm steps.'
        }

        Check-Cancel
        $pb.Value = 100
        Write-Log 'Done.'
        [System.Windows.Forms.MessageBox]::Show("Vencord setup complete.`r`n`r`nRepo: $installDir`r`nPlugins folder: src/userplugins")
    }
    catch {
        $errMsg = $_.Exception.Message
        if ($errMsg -eq 'CANCELLED') {
            Write-Log 'Installation cancelled. Performing cleanup...'
            try { if ($script:targetDir -and (Test-Path $script:targetDir)) { Remove-Item -LiteralPath $script:targetDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
            foreach ($p in $script:tempPaths) { try { if ($p -and (Test-Path $p)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } } catch {} }
            [System.Windows.Forms.MessageBox]::Show('Installation cancelled. Target directory removed.', 'Cancelled', 'OK', 'Information')
        } else {
            Write-Log "FATAL: $errMsg"
            [System.Windows.Forms.MessageBox]::Show("An error occurred: $errMsg", 'Error', 'OK', 'Error')
        }
    }
    finally {
        $form.UseWaitCursor = $false
        $btnInstall.Enabled = $true
        $btnCancel.Enabled = $false
        $script:isInstalling = $false
        $script:currentProcess = $null
        $script:tempPaths.Clear() | Out-Null
    }
})

$form.Add_Shown({ $form.Activate() })
[void]($form.add_FormClosing({
    param($src,$args)
    if ($script:isInstalling -and -not $script:cancelRequested) {
        $script:cancelRequested = $true
        try { if ($script:currentProcess -and -not $script:currentProcess.HasExited) { $script:currentProcess.Kill() } } catch {}
        try { if ($script:targetDir -and (Test-Path $script:targetDir)) { Remove-Item -LiteralPath $script:targetDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
        foreach ($p in $script:tempPaths) { try { if ($p -and (Test-Path $p)) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } } catch {} }
    }
}))
[void]$form.ShowDialog()
