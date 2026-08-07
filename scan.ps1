<#
.SYNOPSIS
    Install Atomdrift Scan (the `atomscan` CLI) on Windows.

.DESCRIPTION
    irm https://install.atomdrift.org/scan.ps1 | iex

    With options, which `iex` cannot pass through:

    & ([scriptblock]::Create((irm https://install.atomdrift.org/scan.ps1))) -Method Binary

    It works out the platform, fetches a release binary (checksum- and
    provenance-verified), falls back to a source build when no binary is
    published for it, puts the install directory on PATH, and installs the
    optional analysis tools available from configured package sources.

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
    Skip optional analysis tool installation (rizin, upx, 7-Zip, innoextract).

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
	'arm-unknown-linux-musleabihf', 'armv7-unknown-linux-musleabihf'
	'loongarch64-unknown-linux-musl'
	's390x-unknown-linux-gnu', 'riscv64gc-unknown-linux-gnu'
	'powerpc64le-unknown-linux-gnu'
	'aarch64-apple-darwin', 'x86_64-apple-darwin'
	'x86_64-unknown-freebsd', 'x86_64-unknown-openbsd'
	'x86_64-unknown-netbsd'
	'x86_64-unknown-illumos', 'x86_64-pc-solaris'
	'x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc'
)

# Filled in as we go.
$script:Self = ''         # this machine's target triple, published or not
$script:Target = ''       # same, but empty unless a release carries it
$script:Resolved = ''     # version being installed
$script:InstallDir = ''
$script:Installed = ''    # full path of the binary we installed
$script:Changed = $false  # whether this run replaced anything
$script:AlreadyCurrent = $false
$script:Temp = ''

# ---------------------------------------------------------------------------
# Style
#
# ANSI when the host can render it, plain text otherwise. Colors follow the
# Atomdrift website: blue for motion, toxic lime for success, amber for
# attention, red for failure, and a readable neutral for supporting detail.
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
			$script:CRed = "$e[38;2;220;38;38m"
			$script:CAmber = "$e[38;2;217;119;6m"
			$script:CGreen = "$e[38;2;74;107;15m"
			$script:CBrand = "$e[38;2;37;99;235m"
			$script:CDim = "$e[38;2;107;114;128m"
		} else {
			$script:CRed = "$e[38;2;248;113;113m"
			$script:CAmber = "$e[38;2;251;191;36m"
			$script:CGreen = "$e[38;2;208;255;0m"
			$script:CBrand = "$e[38;2;96;165;250m"
			$script:CDim = "$e[38;2;161;161;170m"
		}
		$script:CBold = "$e[1m"
		$script:CReset = "$e[0m"
	} else {
		$script:CRed = '' ; $script:CAmber = '' ; $script:CGreen = '' ; $script:CBrand = ''
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
		$script:GScan = ([string][char]0x269B) + [char]0xFE0F
		$script:GStep = [string][char]0x00B7 ; $script:GOk = [string][char]0x2713
		$script:GWarn = [string][char]0x26A0 ; $script:GErr = [string][char]0x2717
	} else {
		$script:GScan = '*' ; $script:GStep = '-' ; $script:GOk = '+'
		$script:GWarn = '!' ; $script:GErr = 'x'
	}

}

function Write-Step([string]$Label, [string]$Value) {
	if ($Quiet) { return }
	Write-Host (" {0}{1}{2} {3}{4}{5}{6}" -f $script:CBrand, $script:GStep, $script:CReset,
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

function Write-Gap {
	if (-not $Quiet) { Write-Host '' }
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
		$script:CBrand, $script:GScan, $script:CReset, $script:CBold, $script:CReset)
	Write-Host ''
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

function Resolve-Platform {
	$arch = $env:PROCESSOR_ARCHITECTURE
	if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
	switch ($arch) {
		'AMD64' { $script:Self = 'x86_64-pc-windows-msvc'; $displayArch = 'x86_64' }
		'ARM64' { $script:Self = 'aarch64-pc-windows-msvc'; $displayArch = 'aarch64' }
		'x86' { $script:Self = 'i686-pc-windows-msvc'; $displayArch = 'i686' }
		default { $script:Self = "$arch-pc-windows-msvc"; $displayArch = $arch.ToLowerInvariant() }
	}
	$script:Target = ''
	if ($Targets -contains $script:Self) { $script:Target = $script:Self }

	$os = 'Windows'
	try {
		$os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption.Trim()
	} catch {
		try { $os = [System.Environment]::OSVersion.VersionString } catch { $os = 'Windows' }
	}
	Write-Step 'platform' ("{0}  {1}{2} {3}{4}" -f $os, $script:CDim, $script:GStep, $displayArch, $script:CReset)
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

# Verify the signed checksum manifest with the portable Sigstore bundle. A
# normal release uses the tag identity; a recovery publish is restricted to
# main by release.yml and therefore uses the second identity.
function Test-SigstoreManifest([string]$Manifest, [string]$Bundle, [string]$ReleaseVersion) {
	if (-not (Get-Command cosign -ErrorAction SilentlyContinue)) { return '' }
	$identities = @(
		"https://github.com/$Repo/.github/workflows/release.yml@refs/tags/v$ReleaseVersion",
		"https://github.com/$Repo/.github/workflows/release.yml@refs/heads/main"
	)
	foreach ($identity in $identities) {
		try {
			& cosign verify-blob $Manifest `
				--bundle $Bundle `
				--certificate-identity $identity `
				--certificate-oidc-issuer 'https://token.actions.githubusercontent.com' *> $null
			if ($LASTEXITCODE -eq 0) { return $identity }
		} catch {
			# Try the recovery identity before reporting failure to the caller.
		}
	}
	return ''
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
	try {
		Copy-Item -LiteralPath $Source -Destination $new -Force
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
		$script:AlreadyCurrent = $true
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

	$sigstoreIdentity = ''
	if (Get-Command cosign -ErrorAction SilentlyContinue) {
		$bundle = Join-Path $script:Temp 'SHA256SUMS.sigstore.json'
		$hasBundle = $false
		try {
			Save-Url "$base/SHA256SUMS.sigstore.json" $bundle 'SHA256SUMS.sigstore.json'
			$hasBundle = $true
		} catch {
			# Older releases predate portable Sigstore bundles; retain the
			# mandatory SHA-256 and optional GitHub attestation checks below.
		}
		if ($hasBundle) {
			$sigstoreIdentity = Test-SigstoreManifest $sums $bundle $script:Resolved
			if (-not $sigstoreIdentity) {
				Stop-Install 'SHA256SUMS has an invalid Sigstore signature - refusing to install'
			}
		}
	}

	$digest = Test-Checksum $archive $sums $name
	$attested = Test-Provenance $archive
	if ($sigstoreIdentity -and $attested) {
		Write-Ok 'verified' "sha256 $digest  $($script:CDim)$([char]0x00B7)  sigstore signed  $([char]0x00B7)  provenance attested$($script:CReset)"
	} elseif ($sigstoreIdentity) {
		Write-Ok 'verified' "sha256 $digest  $($script:CDim)$([char]0x00B7)  sigstore signed$($script:CReset)"
	} elseif ($attested) {
		Write-Ok 'verified' "sha256 $digest  $($script:CDim)$([char]0x00B7)  provenance attested$($script:CReset)"
	} else {
		Write-Ok 'verified' "sha256 $digest"
	}
	if ($sigstoreIdentity) { Write-Note "sigstore signer  $sigstoreIdentity" }

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
	Write-Step 'method' "source  $($script:CDim)git + cargo$($script:CReset)"

	if (-not (Get-Command cargo -ErrorAction SilentlyContinue) -or
		-not (Get-Command rustc -ErrorAction SilentlyContinue)) {
		Stop-Install "a source build needs Rust 1.94 or newer:`n   winget install --id Rustlang.Rustup`n   then re-run this installer"
	}
	$rustOutput = "$(& rustc --version 2>$null)".Trim()
	if ($LASTEXITCODE -ne 0 -or $rustOutput -notmatch '^rustc\s+(\d+)\.(\d+)') {
		Stop-Install "cannot determine the installed Rust version; install Rust 1.94 or newer and re-run this installer"
	}
	$rustMajor = [int]$Matches[1]
	$rustMinor = [int]$Matches[2]
	if ($rustMajor -lt 1 -or ($rustMajor -eq 1 -and $rustMinor -lt 94)) {
		$rustCommand = if (Get-Command rustup -ErrorAction SilentlyContinue) {
			'rustup update stable'
		} else {
			'winget upgrade --id Rustlang.Rustup'
		}
		Stop-Install "a source build needs Rust 1.94 or newer (found $rustOutput):`n   $rustCommand`n   then re-run this installer"
	}
	if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
		Stop-Install "a source build needs git:`n   winget install --id Git.Git"
	}
	if (-not (Get-Command link.exe -ErrorAction SilentlyContinue) -and
		-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
		Write-Warn 'no MSVC linker on PATH - if the build fails, install the C++ build tools:'
		Write-Note 'winget install --id Microsoft.VisualStudio.2022.BuildTools'
	}

	$ref = ''
	if ($Version) {
		$ref = "v$($Version.TrimStart('v'))"
	} elseif ($script:Resolved) {
		# Auto mode can arrive here after resolving a release that lacks a binary.
		$ref = "v$($script:Resolved)"
	} else {
		$latest = Resolve-LatestVersion
		if (-not $latest) { Stop-Install 'could not work out the latest source release; re-run or specify -Version' }
		$ref = "v$latest"
	}
	$script:Resolved = $ref.TrimStart('v')

	$dest = Join-Path $script:InstallDir $ExeName
	$have = Get-InstalledVersion $dest
	if (-not $Force -and $have -and $have -eq $script:Resolved) {
		$script:Installed = $dest
		$script:AlreadyCurrent = $true
		return
	}

	$src = Join-Path $env:LOCALAPPDATA "atomdrift\scan-src"
	$repoUrl = "https://github.com/$Repo.git"
	$parent = Split-Path -Parent $src
	New-Item -ItemType Directory -Force -Path $parent | Out-Null
	$present = Test-Path -LiteralPath $src
	$hasGit = Test-Path -LiteralPath (Join-Path $src '.git')
	$repair = $false
	if ($hasGit) {
		$origin = & git -C $src remote get-url origin 2>$null
		if ($LASTEXITCODE -ne 0 -or "$origin".Trim() -ne $repoUrl) {
			Write-Warn 'cached source checkout has an unexpected origin - replacing it'
			$repair = $true
		} else {
			Write-Step 'checkout' "updating $src"
			& git -C $src fetch --quiet --depth 1 origin $ref
			if ($LASTEXITCODE -ne 0) {
				Write-Warn 'cached source checkout could not be fetched - replacing it'
				$repair = $true
			} else {
				& git -C $src checkout --quiet --force FETCH_HEAD
				if ($LASTEXITCODE -ne 0) {
					Write-Warn 'cached source checkout could not be reset - replacing it'
					$repair = $true
				}
			}
		}
	} elseif ($present) {
		$repair = $true
	}

	if ($repair) {
		# Clone beside an incomplete cache first. If cloning fails, the existing
		# directory remains untouched; after success, replace it transactionally.
		$suffix = [guid]::NewGuid().ToString('N')
		$stage = "$src.clone.$suffix"
		$old = "$src.old.$suffix"
		Write-Step 'checkout' "repairing $src"
		& git clone --quiet --depth 1 --branch $ref $repoUrl $stage
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
	} elseif (-not $present) {
		# Stage the first clone too, so an interrupted clone cannot poison the
		# canonical cache path for the next run.
		$stage = "$src.clone.$([guid]::NewGuid().ToString('N'))"
		Write-Step 'checkout' "cloning $ref into $src"
		& git clone --quiet --depth 1 --branch $ref $repoUrl $stage
		if ($LASTEXITCODE -ne 0) {
			Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
			Stop-Install "cannot clone $Repo at $ref"
		}
		try {
			Move-Item -LiteralPath $stage -Destination $src -ErrorAction Stop
		} catch {
			Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
			Stop-Install "cannot place source checkout at $src"
		}
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
# file types. Install only packages advertised by Scoop or winget's configured
# sources; unavailable tools remain an honest, quiet note.
# ---------------------------------------------------------------------------

function Test-Tool([string[]]$Names) {
	foreach ($n in $Names) {
		if (Get-Command $n -ErrorAction SilentlyContinue) { return $true }
	}
	return $false
}

function Test-ScoopPackage([string]$Name) {
	try {
		& scoop info $Name *> $null
		return $?
	} catch {
		return $false
	}
}

function Test-WingetPackage([string]$Id) {
	try {
		& winget show --id $Id --exact --accept-source-agreements *> $null
		return $?
	} catch {
		return $false
	}
}

function Show-OptionalTools {
	if ($NoTools) { return }
	Write-Gap

	$scoop = [bool](Get-Command scoop -ErrorAction SilentlyContinue)
	$winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

	# name, commands that satisfy it, scoop package, winget id
	$tools = @(
		@{ Name = 'rizin'; Cmds = @('rizin', 'radare2', 'r2'); Scoop = 'rizin'; Winget = '' },
		@{ Name = 'upx'; Cmds = @('upx'); Scoop = 'upx'; Winget = 'UPX.UPX' },
		@{ Name = '7z'; Cmds = @('7z', '7zz'); Scoop = '7zip'; Winget = '7zip.7zip' },
		@{ Name = 'innoextract'; Cmds = @('innoextract'); Scoop = 'innoextract'; Winget = '' }
	)

	$ready = @()
	$unavailable = @()
	$notInstalled = @()
	$scoopPackages = @()
	$scoopTools = @()
	$wingetPackages = @()
	foreach ($tool in $tools) {
		if (Test-Tool $tool.Cmds) {
			$ready += $tool.Name
			continue
		}

		if ($scoop -and $tool.Scoop -and (Test-ScoopPackage $tool.Scoop)) {
			$scoopPackages += $tool.Scoop
			$scoopTools += $tool.Name
		} elseif ($winget -and $tool.Winget -and (Test-WingetPackage $tool.Winget)) {
			$wingetPackages += $tool
		} else {
			$unavailable += $tool.Name
		}
	}

	if ($scoopPackages.Count) {
		Write-Step 'tools' "scoop install $($scoopPackages -join ' ')"
		$scoopInstalled = $false
		try {
			& scoop install @scoopPackages
			$scoopInstalled = $?
		} catch {
			$scoopInstalled = $false
		}
		if ($scoopInstalled) { $ready += $scoopTools } else { $notInstalled += $scoopTools }
	}
	foreach ($tool in $wingetPackages) {
		Write-Step 'tools' "winget install --id $($tool.Winget) --exact"
		$wingetInstalled = $false
		try {
			& winget install --id $($tool.Winget) --exact --accept-package-agreements --accept-source-agreements
			$wingetInstalled = $?
		} catch {
			$wingetInstalled = $false
		}
		if ($wingetInstalled) { $ready += $tool.Name } else { $notInstalled += $tool.Name }
	}

	if ($ready.Count) {
		Write-Ok 'tools' "$($ready -join ' ')  $($script:CDim)deeper analysis ready$($script:CReset)"
	} else {
		Write-Step 'tools' 'core scanner ready'
	}
	if ($unavailable.Count) { Write-Note "not available from configured repositories: $($unavailable -join ' ')" }
	if ($notInstalled.Count) { Write-Note "available, but not installed: $($notInstalled -join ' ')" }
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
	$current = ''
	if ($script:AlreadyCurrent) { $current = "  $($script:CDim)$([char]0x00B7) already current$($script:CReset)" }
	Write-Host ''
	Write-Host (" {0}{1}{2} {3}Ready to scan{4}  {5} {6}{7}" -f
		$script:CGreen, $script:GOk, $script:CReset, $script:CBold, $script:CReset, $BinName, $version, $current)
	Write-Host ("   {0}{1}{2}" -f $script:CDim, $script:Installed, $script:CReset)
	Write-Host ''
	Write-Host ("   {0}Try it{1}" -f $script:CBrand, $script:CReset)
	Write-Host ("   {0}project{1}     {2} .\project" -f $script:CDim, $script:CReset, $BinName)
	Write-Host ("   {0}package{1}     {2} purl npm/left-pad@1.3.0" -f $script:CDim, $script:CReset, $BinName)
	Write-Host ("   {0}explore{1}     {2} --help" -f $script:CDim, $script:CReset, $BinName)
	Write-Host ''
	Write-Host ("   {0}First scan fetches the model, rule, and bloom-filter bundles.{1}" -f
		$script:CDim, $script:CReset)
	Write-Host ''
}

# ---------------------------------------------------------------------------

function Invoke-Install {
	$script:Installed = ''
	$script:Changed = $false
	$script:AlreadyCurrent = $false
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
			Write-Gap
			Write-Ok 'path' "added $(Split-Path -Parent $script:Installed) to your user PATH"
			Write-Note 'open a new terminal for it to take effect everywhere'
		}
	}

	$found = Get-Command $BinName -ErrorAction SilentlyContinue
	if ($found -and $found.Source -and $found.Source -ne $script:Installed) {
		Write-Gap
		Write-Warn "an earlier $BinName on your PATH will still win: $($found.Source)"
	}

	Write-Summary
}

if ($env:ATOMSCAN_INSTALLER_TESTING -ne '1') {
	Invoke-Install
}
