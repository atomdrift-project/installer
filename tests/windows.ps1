# Exercises one generated Windows installer natively. -Unpublished asserts that
# this machine's target has no release binary, so the installer takes the
# source path.
param(
	[ValidatePattern('^[a-z][a-z0-9-]*$')]
	[string]$Product = 'scan',
	[switch]$Unpublished
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# An installer runs itself on load unless <ENV>_INSTALLER_TESTING is set, and
# ENV comes from the same config the installer was rendered from.
$conf = Join-Path $PSScriptRoot "..\products\$Product.conf"
$envLine = Select-String -LiteralPath $conf -Pattern '^ENV="([A-Z0-9_]+)"$' | Select-Object -First 1
if (-not $envLine) { throw "$conf sets no ENV prefix" }
Set-Item -Path "env:$($envLine.Matches[0].Groups[1].Value)_INSTALLER_TESTING" -Value '1'
. (Join-Path $PSScriptRoot "..\$Product.ps1")

Initialize-Style
Resolve-Platform
$expectedTarget = if ($env:EXPECTED_TARGET) { $env:EXPECTED_TARGET } else { 'x86_64-pc-windows-msvc' }
if ($script:Self -ne $expectedTarget) {
	throw "detected $($script:Self), expected $expectedTarget"
}
if ($Unpublished) {
	if ($script:Target) { throw "$($script:Self) is release-backed; drop -Unpublished" }
	Write-Host "ok - native platform -> $($script:Self) (source build)"
} else {
	if ($script:Target -ne $script:Self) { throw "$($script:Self) is not release-backed" }
	Write-Host "ok - native platform -> $($script:Self)"
}

# Available optional tools are installed in one idempotent package-manager
# operation; missing repository entries are not guessed or recommended.
$script:MockScoopArgs = @()
function Test-Tool([string[]]$Names) { return $false }
function Test-ScoopPackage([string]$Name) { return $Name -in @('upx', '7zip') }
function Test-WingetPackage([string]$Id) { return $false }
function scoop { $script:MockScoopArgs = @($args) }
$NoTools = $false
$Quiet = $true
Show-OptionalTools
if (($script:MockScoopArgs -join ' ') -ne 'install upx 7zip') {
	throw "optional tool install was not repository-filtered: $($script:MockScoopArgs -join ' ')"
}
Write-Host 'ok - optional tools are limited to available packages'

# WinGet covers the same tool set when Scoop is unavailable. Keep this as a
# separate pass so the preference for Scoop above cannot hide missing WinGet
# mappings.
$script:MockWingetCalls = @()
function Test-ScoopPackage([string]$Name) { return $false }
function Test-WingetPackage([string]$Id) {
	return $Id -in @('Rizin.Rizin', 'UPX.UPX', '7zip.7zip', 'dscharrer.innoextract')
}
function winget { $script:MockWingetCalls += ($args -join ' ') }
Show-OptionalTools
$expectedWingetCalls = @(
	'install --id Rizin.Rizin --exact --accept-package-agreements --accept-source-agreements',
	'install --id UPX.UPX --exact --accept-package-agreements --accept-source-agreements',
	'install --id 7zip.7zip --exact --accept-package-agreements --accept-source-agreements',
	'install --id dscharrer.innoextract --exact --accept-package-agreements --accept-source-agreements'
)
if (($script:MockWingetCalls -join "`n") -ne ($expectedWingetCalls -join "`n")) {
	throw "optional tools did not use the complete winget mapping:`n$($script:MockWingetCalls -join "`n")"
}
Write-Host 'ok - optional tools are complete with winget'

$root = Join-Path ([System.IO.Path]::GetTempPath()) "$BinName-installer-test-$([guid]::NewGuid().ToString('N'))"
$oldLocalAppData = $env:LOCALAPPDATA
$script:InstallDir = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null

try {
	# Fixture executables that print a version, compiled by Windows PowerShell:
	# PowerShell 7's Add-Type cannot emit a console application, and every
	# Windows release ships powershell.exe whichever shell runs this test.
	$fixtureOne = Join-Path $root "$BinName-one.exe"
	$fixtureTwo = Join-Path $root "$BinName-two.exe"
	foreach ($fixture in @(@($fixtureOne, '9.9.9'), @($fixtureTwo, '9.9.10'))) {
		$exe, $fixtureVersion = $fixture
		$cs = [System.IO.Path]::ChangeExtension($exe, '.cs')
		[System.IO.File]::WriteAllText($cs,
			"public static class Fixture { public static void Main() { System.Console.WriteLine(`"$BinName $fixtureVersion`"); } }")
		& powershell.exe -NoProfile -NonInteractive -Command "Add-Type -LiteralPath '$cs' -OutputAssembly '$exe' -OutputType ConsoleApplication"
		if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw "could not compile $exe" }
	}

	$name = "$BinName-fixture.exe"
	$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureOne).Hash.ToLowerInvariant()
	$sums = Join-Path $root 'SHA256SUMS'
	[System.IO.File]::WriteAllText($sums, "$hash  $name`n")
	$verified = Test-Checksum $fixtureOne $sums $name
	if ($verified -ne $hash.Substring(0, 12)) { throw 'checksum verification failed' }
	Write-Host 'ok - native SHA-256 verification'

	Install-Binary $fixtureOne
	if ((Get-InstalledVersion $script:Installed) -ne '9.9.9') { throw 'initial atomic install failed' }
	Install-Binary $fixtureTwo
	if ((Get-InstalledVersion $script:Installed) -ne '9.9.10') { throw 'atomic replacement failed' }
	Write-Host 'ok - native install and replacement'

	# Full Invoke-Install path with a local release fixture. Overriding these
	# functions after dot-sourcing keeps production URLs and trust behavior
	# untouched while exercising download orchestration, checksum verification,
	# extraction, executable validation, destination handling, and summaries.
	$payload = Join-Path $root 'payload'
	New-Item -ItemType Directory -Force -Path $payload | Out-Null
	Copy-Item -LiteralPath $fixtureTwo -Destination (Join-Path $payload $ExeName)
	$fixtureArchiveName = "$BinName-9.9.10-$expectedTarget.tar.gz"
	$fixtureArchivePath = Join-Path $root $fixtureArchiveName
	& tar.exe -czf $fixtureArchivePath -C $payload $ExeName
	if ($LASTEXITCODE -ne 0) { throw 'could not build Windows release fixture' }
	$fixtureArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixtureArchivePath).Hash.ToLowerInvariant()
	$releaseSums = Join-Path $root 'release-SHA256SUMS'
	[System.IO.File]::WriteAllText($releaseSums, "$fixtureArchiveHash  $fixtureArchiveName`n")

	# The fixture release publishes this machine's target, whether or not the
	# real releases do.
	$Targets = @($expectedTarget)
	function Test-UrlExists([string]$Url) { return $true }
	function Test-Provenance([string]$File) { return $false }
	function cosign { return }
	function Test-SigstoreManifest([string]$Manifest, [string]$Bundle, [string]$ReleaseVersion) {
		return "https://github.com/$Repo/.github/workflows/release.yml@refs/tags/v9.9.10"
	}
	function Save-Url([string]$Url, [string]$Path, [string]$Label) {
		if ($Url.EndsWith('/SHA256SUMS')) {
			Copy-Item -LiteralPath $releaseSums -Destination $Path
		} elseif ($Url.EndsWith('/SHA256SUMS.sigstore.json')) {
			[System.IO.File]::WriteAllText($Path, '{}')
		} elseif ($Url.EndsWith("/$fixtureArchiveName")) {
			Copy-Item -LiteralPath $fixtureArchivePath -Destination $Path
		} else {
			throw "unexpected fixture URL: $Url"
		}
	}

	$integrationDir = Join-Path $root 'integration-bin'
	$Version = '9.9.10'
	$Dir = $integrationDir
	$Method = 'Binary'
	$NoTools = $true
	$NoUpdate = $true
	$NoPath = $true
	$Force = $false
	$Quiet = $true
	Invoke-Install
	$expectedInstall = Join-Path $integrationDir $ExeName
	if ($script:Installed -ne $expectedInstall) { throw "installed at unexpected path $($script:Installed)" }
	if ((Get-InstalledVersion $script:Installed) -ne '9.9.10') { throw 'end-to-end fixture does not run' }
	Write-Host "ok - end-to-end binary install -> $($script:Installed)"

	# The post-install update and the summary are rendered per product: the
	# update command may be empty and the examples come from the config, so
	# run both against the fixture under strict mode.
	$NoUpdate = $false
	Update-Rules
	$Quiet = $false
	Write-Summary
	$Quiet = $true
	Write-Host 'ok - post-install update and summary'

	# Source checkouts are cloned into a unique sibling first. Exercise recovery
	# from a pre-existing non-Git cache and reuse of the promoted checkout.
	$env:LOCALAPPDATA = Join-Path $root 'local-app-data'
	$sourceCache = Join-Path $env:LOCALAPPDATA "atomdrift\$Product-src"
	New-Item -ItemType Directory -Force -Path $sourceCache | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $sourceCache 'interrupted'), "partial`n")
	$script:MockClones = 0
	$script:MockFetches = 0
	$script:MockCheckouts = 0
	$script:MockOrigin = "https://github.com/$Repo.git"
	function git {
		if ($args[0] -eq 'clone') {
			$mockDest = "$($args[-1])"
			New-Item -ItemType Directory -Force -Path (Join-Path $mockDest '.git') | Out-Null
			$script:MockClones++
			$global:LASTEXITCODE = 0
			return
		}
		if ($args[0] -eq '-C') {
			switch ($args[2]) {
				'remote' { Write-Output $script:MockOrigin }
				'fetch' { $script:MockFetches++ }
				'checkout' { $script:MockCheckouts++ }
				default { throw "unexpected mocked git operation: $($args[2])" }
			}
			$global:LASTEXITCODE = 0
			return
		}
		throw "unexpected mocked git invocation: $args"
	}
	function cargo {
		$mockBuilt = Join-Path (Get-Location) 'target\release'
		New-Item -ItemType Directory -Force -Path $mockBuilt | Out-Null
		Copy-Item -LiteralPath $fixtureOne -Destination (Join-Path $mockBuilt $ExeName) -Force
		$global:LASTEXITCODE = 0
	}
	function rustc {
		Write-Output 'rustc 1.97.0 (test toolchain)'
		$global:LASTEXITCODE = 0
	}

	$Version = '2.5.0'
	$Force = $true
	$script:InstallDir = Join-Path $root 'source-bin'
	New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
	Install-FromSource
	if (-not (Test-Path -LiteralPath (Join-Path $sourceCache '.git'))) { throw 'source cache repair failed' }
	if (Test-Path -LiteralPath (Join-Path $sourceCache 'interrupted')) { throw 'incomplete source cache survived repair' }
	if ($script:MockClones -ne 1) { throw 'source cache repair did not clone exactly once' }

	Install-FromSource
	if ($script:MockClones -ne 1 -or $script:MockFetches -ne 1 -or $script:MockCheckouts -ne 1) {
		throw 'valid source cache was not reused'
	}
	$script:MockOrigin = 'https://example.invalid/not-atomdrift.git'
	Install-FromSource
	if ($script:MockClones -ne 2) { throw 'wrong-origin source cache was not replaced' }
	Write-Host 'ok - source cache repair and reuse'
} finally {
	Remove-Item Function:\git -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\cargo -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\rustc -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\scoop -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\winget -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\Test-Tool -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\Test-ScoopPackage -Force -ErrorAction SilentlyContinue
	Remove-Item Function:\Test-WingetPackage -Force -ErrorAction SilentlyContinue
	$env:LOCALAPPDATA = $oldLocalAppData
	Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
