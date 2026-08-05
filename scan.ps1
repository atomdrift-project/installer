<#
.SYNOPSIS
    Install Atomdrift Scan (the `atomscan` CLI) on Windows.

.DESCRIPTION
    irm https://install.atomdrift.org/scan.ps1 | iex

    With options, which `iex` cannot pass through:

    & ([scriptblock]::Create((irm https://install.atomdrift.org/scan.ps1))) -Method Binary

    It works out the platform, fetches a release binary (checksum- and
    provenance-verified), falls back to a source build when no binary is
    published for it, puts the install directory on PATH, and reports on the
    optional analysis tools that make scans deeper.

    Re-running is safe and cheap: an install that is already current is left
    alone, and the binary is replaced atomically.

    Windows PowerShell 5.1 (which ships with Windows 10 and 11) and
    PowerShell 7 are both supported.

.PARAMETER Version
    Install a specific version. Defaults to the latest release.

.PARAMETER Dir
    Install into this directory. Defaults to %LOCALAPPDATA%\Programs\atomscan\bin.

.PARAMETER Method
    Auto, Binary, or Source. Auto tries a release binary, then a source build.

.PARAMETER NoTools
    Skip the optional analysis tool check (rizin, upx, 7-Zip, innoextract).

.PARAMETER NoPath
    Do not add the install directory to the user PATH.

.PARAMETER Force
    Reinstall even when the target version is already there.

.PARAMETER Quiet
    Only report problems.

.LINK
    https://github.com/atomdrift-project/scan
#>

[CmdletBinding()]
# Write-Host is the point here: this is a terminal UI, and its output must not
# land in a caller's pipeline. The rest are analyzer heuristics that misread an
# installer: the parameters are read inside script-scoped functions, and no
# function here changes system state without the caller having asked it to.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
param(
	[string]$Version = $env:ATOMSCAN_VERSION,
	[string]$Dir = $env:ATOMSCAN_INSTALL_DIR,
	[ValidateSet('Auto', 'Binary', 'Source')]
	[string]$Method = 'Auto',
	[switch]$NoTools,
	[switch]$NoPath,
	[switch]$Force,
	[switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest's own progress bar is both slow and redundant here.
$ProgressPreference = 'SilentlyContinue'

$Repo = 'atomdrift-project/scan'
$BinName = 'atomscan'
$ExeName = 'atomscan.exe'

# Targets published by .github/workflows/release.yml.
$Targets = @(
	'x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu'
	'x86_64-unknown-linux-musl', 'aarch64-unknown-linux-musl'
	's390x-unknown-linux-gnu', 'riscv64gc-unknown-linux-gnu'
	'powerpc64le-unknown-linux-gnu'
	'aarch64-apple-darwin', 'x86_64-apple-darwin'
	'x86_64-unknown-freebsd', 'x86_64-unknown-openbsd'
	'x86_64-unknown-netbsd', 'x86_64-unknown-dragonfly'
	'x86_64-unknown-haiku', 'x86_64-unknown-hurd-gnu'
	'x86_64-unknown-illumos', 'x86_64-pc-solaris'
	'x86_64-pc-windows-msvc'
)

# Filled in as we go.
$script:Self = ''         # this machine's target triple, published or not
$script:Target = ''       # same, but empty unless a release carries it
$script:Resolved = ''     # version being installed
$script:InstallDir = ''
$script:Installed = ''    # full path of the binary we installed
$script:Changed = $false  # whether this run replaced anything
$script:Temp = ''

# ---------------------------------------------------------------------------
# Style
#
# ANSI when the host can render it, plain text otherwise. Colors match Scan's
# litmus palette: green for success, amber for attention, red for failure, and
# neutral grey for ordinary progress.
# ---------------------------------------------------------------------------

function Initialize-Style {
	$ansi = $false
	$redirected = $false
	try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $false }
	if (-not $redirected -and $null -eq [Environment]::GetEnvironmentVariable('NO_COLOR')) {
		if ($env:WT_SESSION) {
			$ansi = $true
		} else {
			try { $ansi = [bool]$Host.UI.SupportsVirtualTerminal } catch { $ansi = $false }
		}
	}

	$e = [char]27
	if ($ansi) {
		if ($env:SCAN_THEME -in @('light', 'white')) {
			$script:CRed = "$e[38;2;200;30;30m"
			$script:CAmber = "$e[38;2;180;120;0m"
			$script:CGreen = "$e[38;2;30;140;30m"
			$script:CDim = "$e[38;2;120;120;120m"
		} else {
			$script:CRed = "$e[38;2;255;70;70m"
			$script:CAmber = "$e[38;2;255;175;55m"
			$script:CGreen = "$e[38;2;80;200;80m"
			$script:CDim = "$e[38;2;100;100;100m"
		}
		$script:CBold = "$e[1m"
		$script:CReset = "$e[0m"
	} else {
		$script:CRed = '' ; $script:CAmber = '' ; $script:CGreen = ''
		$script:CDim = '' ; $script:CBold = '' ; $script:CReset = ''
	}

	# Build glyphs from code points to keep this file pure ASCII, which prevents
	# Windows PowerShell 5.1 from mangling it when saved without a byte-order mark.
	$script:Utf8 = $false
	try {
		[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
		$script:Utf8 = $true
	} catch {
		$script:Utf8 = $false
	}
	if ($script:Utf8) {
		$script:GScan = [char]::ConvertFromUtf32(0x1F50D)
		$script:GStep = [string][char]0x00B7 ; $script:GOk = [string][char]0x2713
		$script:GWarn = [string][char]0x26A0 ; $script:GErr = [string][char]0x2717
	} else {
		$script:GScan = '*' ; $script:GStep = '-' ; $script:GOk = '+'
		$script:GWarn = '!' ; $script:GErr = 'x'
	}

}

function Write-Step([string]$Label, [string]$Value) {
	if ($Quiet) { return }
	Write-Host (" {0}{1}{2} {3}{4}{5}{6}" -f $script:CDim, $script:GStep, $script:CReset,
		$script:CDim, $Label.PadRight(11), $script:CReset, $Value)
}

function Write-Ok([string]$Label, [string]$Value) {
	if ($Quiet) { return }
	Write-Host (" {0}{1}{2} {3}{4}{5}{6}" -f $script:CGreen, $script:GOk, $script:CReset,
		$script:CDim, $Label.PadRight(11), $script:CReset, $Value)
}

function Write-Note([string]$Text) {
	if ($Quiet) { return }
	Write-Host ("   {0}{1}{2}" -f $script:CDim, $Text, $script:CReset)
}

function Write-Warn([string]$Text) {
	Write-Host (" {0}{1}{2} {3}" -f $script:CAmber, $script:GWarn, $script:CReset, $Text)
}

function Stop-Install([string]$Text) {
	Write-Host ''
	Write-Host (" {0}{1}{2} {3}{4}{5}" -f $script:CRed, $script:GErr, $script:CReset,
		$script:CBold, $Text, $script:CReset)
	Write-Host ''
	exit 1
}

function Write-Banner {
	if ($Quiet) { return }
	Write-Host ''
	Write-Host (" {0}{1}{2} {3}Installing Atomdrift Scan{4}" -f
		$script:CDim, $script:GScan, $script:CReset, $script:CBold, $script:CReset)
	Write-Host ''
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

function Resolve-Platform {
	$arch = $env:PROCESSOR_ARCHITECTURE
	if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
	switch ($arch) {
		'AMD64' { $script:Self = 'x86_64-pc-windows-msvc' }
		'ARM64' { $script:Self = 'aarch64-pc-windows-msvc' }
		'x86' { $script:Self = 'i686-pc-windows-msvc' }
		default { $script:Self = "$arch-pc-windows-msvc" }
	}
	$script:Target = ''
	if ($Targets -contains $script:Self) { $script:Target = $script:Self }

	$os = 'Windows'
	try {
		$os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption.Trim()
	} catch {
		try { $os = [System.Environment]::OSVersion.VersionString } catch { $os = 'Windows' }
	}
	Write-Step 'platform' ("{0}  {1}{2}{3}" -f $script:Self, $script:CDim, $os, $script:CReset)
}

# ---------------------------------------------------------------------------
# HTTP
#
# HttpWebRequest rather than Invoke-WebRequest: it is present in Windows
# PowerShell 5.1 and PowerShell 7 alike, it streams, and it reports the length
# up front, which is what the progress bar is drawn from.
# ---------------------------------------------------------------------------

function Initialize-Tls {
	try {
		[Net.ServicePointManager]::SecurityProtocol =
		[Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
	} catch {
		# .NET Framework 4.7 and earlier have no Tls13 member to name.
		try {
			[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		} catch {
			Write-Verbose "leaving SecurityProtocol at its default: $_"
		}
	}
}

function New-Request([string]$Url) {
	$req = [System.Net.HttpWebRequest]::Create($Url)
	$req.UserAgent = "atomscan-install/1.0 (PowerShell $($PSVersionTable.PSVersion))"
	$req.Timeout = 30000
	$req.ReadWriteTimeout = 120000
	return $req
}

# The newest release tag, read from the redirect /releases/latest performs. The
# REST API would do too, but it is rate-limited per IP, which is exactly the
# wrong failure mode on a shared CI address.
function Resolve-LatestVersion {
	try {
		$req = New-Request "https://github.com/$Repo/releases/latest"
		$req.Method = 'HEAD'
		$resp = $req.GetResponse()
		$uri = $resp.ResponseUri.AbsoluteUri
		$resp.Dispose()
		if ($uri -match '/releases/tag/(.+)$') { return $Matches[1].TrimStart('v') }
	} catch {
		Write-Verbose "latest-release redirect failed: $_"
	}

	# Shared CI addresses can exhaust GitHub's API quota, so this is deliberately
	# the fallback rather than the primary path.
	$resp = $null ; $reader = $null
	try {
		$req = New-Request "https://api.github.com/repos/$Repo/releases/latest"
		$resp = $req.GetResponse()
		$reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
		$release = $reader.ReadToEnd() | ConvertFrom-Json
		if ($release.tag_name) { return ("$($release.tag_name)").TrimStart('v') }
	} catch {
		Write-Verbose "latest-release API fallback failed: $_"
	} finally {
		if ($reader) { $reader.Dispose() }
		if ($resp) { $resp.Dispose() }
	}
	return ''
}

# Deliberately narrow: only a 404 counts as absent. A HEAD refused for any other
# reason must not be read as "this platform has no binary", or a working release
# would quietly become a very long source build.
function Test-UrlExists([string]$Url) {
	try {
		$req = New-Request $Url
		$req.Method = 'HEAD'
		$resp = $req.GetResponse()
		$resp.Dispose()
		return $true
	} catch [System.Net.WebException] {
		$response = $_.Exception.Response
		if ($response -and [int]$response.StatusCode -eq 404) { return $false }
		return $true
	} catch {
		return $true
	}
}

function Format-Size([long]$Bytes) {
	if ($Bytes -ge 1048576) { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
	if ($Bytes -ge 1024) { return ('{0:N0} KB' -f ($Bytes / 1024)) }
	return "$Bytes B"
}

function Save-Url([string]$Url, [string]$Path, [string]$Label) {
	$resp = $null ; $in = $null ; $out = $null
	Write-Step 'download' $Label
	try {
		$resp = (New-Request $Url).GetResponse()
		$in = $resp.GetResponseStream()
		$out = [System.IO.File]::Create($Path)
		$buffer = New-Object byte[] 131072
		while ($true) {
			$read = $in.Read($buffer, 0, $buffer.Length)
			if ($read -le 0) { break }
			$out.Write($buffer, 0, $read)
		}
	} finally {
		if ($out) { $out.Dispose() }
		if ($in) { $in.Dispose() }
		if ($resp) { $resp.Dispose() }
	}
	$size = (Get-Item $Path).Length
	Write-Note "downloaded $(Format-Size $size)"
}

# ---------------------------------------------------------------------------
# Integrity
# ---------------------------------------------------------------------------

# Fails closed. The digest travels over the same TLS connection as the archive,
# so this is a corruption and truncation check; the attestation below is the
# trust anchor.
function Test-Checksum([string]$File, [string]$SumsFile, [string]$Name) {
	$want = ''
	foreach ($line in [System.IO.File]::ReadAllLines($SumsFile)) {
		$fields = $line -split '\s+', 2
		if ($fields.Count -lt 2) { continue }
		$listed = $fields[1].Trim()
		if ($listed.StartsWith('./')) { $listed = $listed.Substring(2) }
		if ($listed.StartsWith('*')) { $listed = $listed.Substring(1) }
		if ($listed -eq $Name) { $want = $fields[0].Trim().ToLowerInvariant(); break }
	}
	if (-not $want) { Stop-Install "$Name is not listed in SHA256SUMS - refusing to install" }

	$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash.ToLowerInvariant()
	if ($got -ne $want) {
		Stop-Install "checksum mismatch for $Name - refusing to install`n   expected $want`n   got      $got"
	}
	return $got.Substring(0, 12)
}

# Signed build provenance, when the GitHub CLI is here to check it. Its absence
# is not an error: this is a stronger check than we can otherwise make, not a
# required one.
function Test-Provenance([string]$File) {
	if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
	try {
		& gh attestation verify $File --repo $Repo *> $null
		return $LASTEXITCODE -eq 0
	} catch {
		return $false
	}
}

# ---------------------------------------------------------------------------
# Install location
#
# %LOCALAPPDATA%\Programs is where a per-user install belongs on Windows: no
# administrator rights, no UAC prompt, and nothing left in Program Files for
# another user to trip over.
# ---------------------------------------------------------------------------

function Resolve-InstallDir {
	if ($Dir) {
		$script:InstallDir = $Dir
	} else {
		$existing = Get-Command $BinName -ErrorAction SilentlyContinue
		if ($existing -and $existing.Source) {
			# Upgrading in place beats installing a second copy that shadows the
			# first.
			$script:InstallDir = Split-Path -Parent $existing.Source
		} else {
			$script:InstallDir = Join-Path $env:LOCALAPPDATA "Programs\$BinName\bin"
		}
	}
	if (-not (Test-Path -LiteralPath $script:InstallDir)) {
		New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
	}
}

function Get-InstalledVersion([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path)) { return '' }
	try {
		$out = & $Path --version 2>$null
		if ($LASTEXITCODE -ne 0) { return '' }
		return ("$out".Trim() -split '\s+')[1]
	} catch {
		return ''
	}
}

# Replace the binary by rename rather than by overwrite: a reader sees either
# the old file or the new one, and a running atomscan.exe cannot be written to
# in place on Windows at all.
function Install-Binary([string]$Source) {
	$dest = Join-Path $script:InstallDir $ExeName
	$suffix = [guid]::NewGuid().ToString('N')
	$new = "$dest.new.$suffix"
	$old = "$dest.old.$suffix"
	Copy-Item -LiteralPath $Source -Destination $new -Force
	try {
		if (Test-Path -LiteralPath $dest) {
			[System.IO.File]::Replace($new, $dest, $old, $true)
		} else {
			Move-Item -LiteralPath $new -Destination $dest
		}
	} catch {
		Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
		Stop-Install "cannot replace $dest - is atomscan running?"
	}
	# A previous copy can stay locked by a running process; it is not fatal.
	Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
	$script:Installed = $dest
	$script:Changed = $true
}

# ---------------------------------------------------------------------------
# Method: release binary
#
# Returns $false when this platform has no published binary - the signal for
# main to fall back to a source build.
# ---------------------------------------------------------------------------

function Install-FromRelease {
	if (-not $script:Target) {
		Write-Warn "no published binary for $($script:Self)"
		return $false
	}

	if ($Version) {
		$script:Resolved = $Version.TrimStart('v')
	} else {
		$script:Resolved = Resolve-LatestVersion
		if (-not $script:Resolved) {
			Write-Warn 'could not work out the latest release'
			return $false
		}
	}
	$pinned = ''
	if ($Version) { $pinned = "  $($script:CDim)(pinned)$($script:CReset)" }
	Write-Step 'version' "$($script:Resolved)$pinned"

	# Idempotence: an install that is already what we would install is done.
	$dest = Join-Path $script:InstallDir $ExeName
	if (-not $Force -and (Get-InstalledVersion $dest) -eq $script:Resolved) {
		$script:Installed = $dest
		Write-Ok 'up to date' "$dest  $($script:CDim)$($script:Resolved)$($script:CReset)"
		return $true
	}

	$name = "$BinName-$($script:Resolved)-$($script:Target).tar.gz"
	$base = "https://github.com/$Repo/releases/download/v$($script:Resolved)"
	if (-not (Test-UrlExists "$base/$name")) {
		Write-Warn "release v$($script:Resolved) publishes no binary for $($script:Target)"
		return $false
	}

	Write-Step 'method' "release binary  $($script:CDim)$($script:Target)$($script:CReset)"
	$archive = Join-Path $script:Temp $name
	Save-Url "$base/$name" $archive $name

	$sums = Join-Path $script:Temp 'SHA256SUMS'
	try {
		Save-Url "$base/SHA256SUMS" $sums 'SHA256SUMS'
	} catch {
		Stop-Install "release v$($script:Resolved) publishes no SHA256SUMS - refusing to install unverified"
	}

	$digest = Test-Checksum $archive $sums $name
	if (Test-Provenance $archive) {
		Write-Ok 'verified' "sha256 $digest  $($script:CDim)$([char]0x00B7)  provenance attested$($script:CReset)"
	} else {
		Write-Ok 'verified' "sha256 $digest"
	}

	# bsdtar has shipped in Windows since 10 build 17063 and reads .tar.gz
	# directly; nothing else in the box does.
	if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
		Stop-Install 'tar.exe is missing - Windows 10 build 17063 or newer is required for the binary install'
	}
	$unpack = Join-Path $script:Temp 'x'
	New-Item -ItemType Directory -Force -Path $unpack | Out-Null
	& tar.exe -xzf $archive -C $unpack
	if ($LASTEXITCODE -ne 0) { Stop-Install "cannot unpack $name" }

	$exe = Join-Path $unpack $ExeName
	if (-not (Test-Path -LiteralPath $exe)) { Stop-Install "$name does not contain $ExeName" }
	try {
		& $exe --version *> $null
		if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
	} catch {
		Write-Warn "the $($script:Target) release binary does not run on this machine"
		return $false
	}
	Install-Binary $exe
	return $true
}

# ---------------------------------------------------------------------------
# Method: source
#
# The checkout stays in the cache directory so a later source build is
# incremental rather than cold.
# ---------------------------------------------------------------------------

function Install-FromSource {
	Write-Step 'method' "source build  $($script:CDim)git + cargo$($script:CReset)"

	if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
		Stop-Install "a source build needs git:`n   winget install --id Git.Git"
	}
	if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
		Stop-Install "a source build needs Rust 1.94 or newer:`n   winget install --id Rustlang.Rustup"
	}
	if (-not (Get-Command link.exe -ErrorAction SilentlyContinue) -and
		-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
		Write-Warn 'no MSVC linker on PATH - if the build fails, install the C++ build tools:'
		Write-Note 'winget install --id Microsoft.VisualStudio.2022.BuildTools'
	}

	$ref = 'main'
	if ($Version) {
		$ref = "v$($Version.TrimStart('v'))"
	} else {
		$latest = Resolve-LatestVersion
		if ($latest) { $ref = "v$latest" }
	}
	$script:Resolved = $ref.TrimStart('v')

	$dest = Join-Path $script:InstallDir $ExeName
	$have = Get-InstalledVersion $dest
	if (-not $Force -and $have -and $have -eq $script:Resolved) {
		$script:Installed = $dest
		Write-Ok 'up to date' "$dest  $($script:CDim)$($script:Resolved)$($script:CReset)"
		return
	}

	$src = Join-Path $env:LOCALAPPDATA "atomdrift\scan-src"
	if (Test-Path -LiteralPath (Join-Path $src '.git')) {
		Write-Step 'source' "updating $src"
		& git -C $src fetch --quiet --depth 1 origin $ref
		if ($LASTEXITCODE -ne 0) { Stop-Install "cannot fetch $ref" }
		& git -C $src checkout --quiet --force FETCH_HEAD
		if ($LASTEXITCODE -ne 0) { Stop-Install "cannot check out $ref" }
	} elseif (Test-Path -LiteralPath $src) {
		# Clone beside an incomplete cache first. If cloning fails, the existing
		# directory remains untouched; after success, replace it transactionally.
		$suffix = [guid]::NewGuid().ToString('N')
		$stage = "$src.clone.$suffix"
		$old = "$src.old.$suffix"
		Write-Step 'source' "repairing incomplete checkout at $src"
		& git clone --quiet --depth 1 --branch $ref "https://github.com/$Repo.git" $stage
		if ($LASTEXITCODE -ne 0) {
			Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
			Stop-Install "cannot clone $Repo at $ref"
		}
		try {
			Move-Item -LiteralPath $src -Destination $old -ErrorAction Stop
			try {
				Move-Item -LiteralPath $stage -Destination $src -ErrorAction Stop
				Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
			} catch {
				Move-Item -LiteralPath $old -Destination $src -ErrorAction SilentlyContinue
				throw
			}
		} catch {
			Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
			Stop-Install "cannot replace incomplete checkout at $src"
		}
	} else {
		Write-Step 'source' "cloning $ref into $src"
		New-Item -ItemType Directory -Force -Path (Split-Path -Parent $src) | Out-Null
		& git clone --quiet --depth 1 --branch $ref "https://github.com/$Repo.git" $src
		if ($LASTEXITCODE -ne 0) { Stop-Install "cannot clone $Repo at $ref" }
	}

	Write-Step 'build' "cargo build --release  $($script:CDim)(the analysis stack is large - expect a long build)$($script:CReset)"
	Push-Location $src
	try {
		& cargo build --release --locked --bin $BinName
		if ($LASTEXITCODE -ne 0) { Stop-Install "build failed in $src" }
	} finally {
		Pop-Location
	}

	$built = Join-Path $src "target\release\$ExeName"
	if (-not (Test-Path -LiteralPath $built)) { Stop-Install "the build produced no $ExeName" }
	if (-not (Get-InstalledVersion $built)) { Stop-Install "the newly built $ExeName does not run" }
	Install-Binary $built
	Write-Note "source checkout kept at $src - delete it to reclaim the space"
}

# ---------------------------------------------------------------------------
# Optional analysis tools
#
# None of these are required: scans work without them, with less depth on some
# file types. Report exact package-manager commands, but leave installation to
# the user rather than silently changing the machine from a piped installer.
# ---------------------------------------------------------------------------

function Test-Tool([string[]]$Names) {
	foreach ($n in $Names) {
		if (Get-Command $n -ErrorAction SilentlyContinue) { return $true }
	}
	return $false
}

function Show-OptionalTools {
	if ($NoTools) { return }

	$scoop = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
	$winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

	# name, commands that satisfy it, scoop package, winget id
	$tools = @(
		@{ Name = 'rizin'; Cmds = @('rizin', 'radare2', 'r2'); Scoop = 'rizin'; Winget = '' },
		@{ Name = 'upx'; Cmds = @('upx'); Scoop = 'upx'; Winget = 'UPX.UPX' },
		@{ Name = '7z'; Cmds = @('7z', '7zz'); Scoop = '7zip'; Winget = '7zip.7zip' },
		@{ Name = 'innoextract'; Cmds = @('innoextract'); Scoop = 'innoextract'; Winget = '' }
	)

	$report = @()
	$pending = @()
	foreach ($tool in $tools) {
		if (Test-Tool $tool.Cmds) {
			$report += "$($script:CGreen)$($script:GOk)$($script:CReset)$($tool.Name)"
			continue
		}

		$report += "$($script:CDim)-$($tool.Name)$($script:CReset)"
		if ($scoop -and $tool.Scoop) {
			$pending += "scoop install $($tool.Scoop)"
		} elseif ($winget -and $tool.Winget) {
			$pending += "winget install --id $($tool.Winget)"
		} elseif ($tool.Name -eq 'rizin') {
			$pending += 'https://rizin.re/download/'
		}
	}

	Write-Step 'tools' (($report -join ' ') + "  $($script:CDim)optional$($script:CReset)")
	foreach ($cmd in $pending) { Write-Note "for deeper analysis:  $cmd" }
}

# ---------------------------------------------------------------------------
# PATH
#
# The user PATH, never the machine one: this is a per-user install and editing
# the machine PATH would need administrator rights we deliberately never ask
# for. Adding it twice is the classic installer bug, so check first.
# ---------------------------------------------------------------------------

function Add-ToUserPath([string]$Directory) {
	$current = [Environment]::GetEnvironmentVariable('Path', 'User')
	if ($null -eq $current) { $current = '' }
	$parts = $current -split ';' | Where-Object { $_ -ne '' }
	foreach ($p in $parts) {
		if ($p.TrimEnd('\') -ieq $Directory.TrimEnd('\')) { return $false }
	}
	$updated = if ($current) { "$current;$Directory" } else { $Directory }
	[Environment]::SetEnvironmentVariable('Path', $updated, 'User')
	# Make it work in this session too, not only in the next one.
	$env:Path = "$env:Path;$Directory"
	return $true
}

function Write-Summary {
	if ($Quiet) { return }
	$version = Get-InstalledVersion $script:Installed
	if (-not $version) { $version = $script:Resolved }
	Write-Host ''
	Write-Host (" {0}{1}{2} {3}{4} {5}{6}  {7}{8}{9}" -f
		$script:CGreen, $script:GOk, $script:CReset, $script:CBold, $BinName, $version,
		$script:CReset, $script:CDim, $script:Installed, $script:CReset)
	Write-Host ''
	Write-Host ("   {0}scan a project{1}     {2} .\project" -f $script:CDim, $script:CReset, $BinName)
	Write-Host ("   {0}scan a package{1}     {2} purl npm/left-pad@1.3.0" -f $script:CDim, $script:CReset, $BinName)
	Write-Host ("   {0}everything else{1}    {2} --help" -f $script:CDim, $script:CReset, $BinName)
	Write-Host ''
	Write-Host ("   {0}The first scan downloads the model, rule, and bloom-filter bundles.{1}" -f
		$script:CDim, $script:CReset)
	Write-Host ''
}

# ---------------------------------------------------------------------------

function Invoke-Install {
	Initialize-Style
	if ($Version -and $Version.TrimStart('v') -notmatch '^[0-9A-Za-z._+-]+$') {
		Stop-Install "invalid version '$Version'"
	}
	Initialize-Tls
	Write-Banner
	Resolve-Platform

	$script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) "atomscan-install-$([guid]::NewGuid().ToString('N'))"
	New-Item -ItemType Directory -Force -Path $script:Temp | Out-Null
	try {
		Resolve-InstallDir

		$chosen = $Method
		$auto = $chosen -eq 'Auto'
		if ($auto) { $chosen = 'Binary' }
		if ($chosen -eq 'Binary') {
			if (-not (Install-FromRelease)) {
				if ($auto) {
					Write-Note 'no binary available - building from source instead'
					$chosen = 'Source'
				} else {
					Stop-Install 'the requested binary install could not be completed'
				}
			}
		}
		if ($chosen -eq 'Source') { Install-FromSource }
	} finally {
		Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
	}

	if (-not $script:Installed) { Stop-Install 'the install produced no binary' }
	if (-not (Get-InstalledVersion $script:Installed)) {
		Stop-Install "$($script:Installed) does not run on this machine"
	}
	if ($script:Changed) { Write-Ok 'installed' $script:Installed }

	Show-OptionalTools

	if (-not $NoPath) {
		if (Add-ToUserPath (Split-Path -Parent $script:Installed)) {
			Write-Ok 'path' "added $(Split-Path -Parent $script:Installed) to your user PATH"
			Write-Note 'open a new terminal for it to take effect everywhere'
		}
	}

	$found = Get-Command $BinName -ErrorAction SilentlyContinue
	if ($found -and $found.Source -and $found.Source -ne $script:Installed) {
		Write-Warn "an earlier $BinName on your PATH will still win: $($found.Source)"
	}

	Write-Summary
}

if ($env:ATOMSCAN_INSTALLER_TESTING -ne '1') {
	Invoke-Install
}
