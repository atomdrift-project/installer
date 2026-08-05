$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$env:ATOMSCAN_INSTALLER_TESTING = '1'
. (Join-Path $PSScriptRoot '..\scan.ps1')

Initialize-Style
Resolve-Platform
if ($script:Self -ne 'x86_64-pc-windows-msvc') {
	throw "detected $($script:Self), expected x86_64-pc-windows-msvc"
}
if ($script:Target -ne $script:Self) {
	throw "$($script:Self) is not release-backed"
}
Write-Host "ok - native platform -> $($script:Self)"

$root = Join-Path ([System.IO.Path]::GetTempPath()) "atomscan-installer-test-$([guid]::NewGuid().ToString('N'))"
$oldLocalAppData = $env:LOCALAPPDATA
$script:InstallDir = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null

try {
	$fixtureOne = Join-Path $root 'atomscan-one.exe'
	$fixtureTwo = Join-Path $root 'atomscan-two.exe'
	$sourceOne = @'
using System;
public static class FixtureOne {
    public static void Main() { Console.WriteLine("atomscan 9.9.9"); }
}
'@
	$sourceTwo = @'
using System;
public static class FixtureTwo {
    public static void Main() { Console.WriteLine("atomscan 9.9.10"); }
}
'@
	Add-Type -TypeDefinition $sourceOne -OutputAssembly $fixtureOne -OutputType ConsoleApplication
	Add-Type -TypeDefinition $sourceTwo -OutputAssembly $fixtureTwo -OutputType ConsoleApplication

	$name = 'atomscan-fixture.exe'
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
	Copy-Item -LiteralPath $fixtureTwo -Destination (Join-Path $payload 'atomscan.exe')
	$archiveName = 'atomscan-9.9.10-x86_64-pc-windows-msvc.tar.gz'
	$archive = Join-Path $root $archiveName
	& tar.exe -czf $archive -C $payload atomscan.exe
	if ($LASTEXITCODE -ne 0) { throw 'could not build Windows release fixture' }
	$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
	$releaseSums = Join-Path $root 'release-SHA256SUMS'
	[System.IO.File]::WriteAllText($releaseSums, "$archiveHash  $archiveName`n")

	function Test-UrlExists([string]$Url) { return $true }
	function Test-Provenance([string]$File) { return $false }
	function Save-Url([string]$Url, [string]$Path, [string]$Label) {
		if ($Url.EndsWith('/SHA256SUMS')) {
			Copy-Item -LiteralPath $releaseSums -Destination $Path
		} elseif ($Url.EndsWith("/$archiveName")) {
			Copy-Item -LiteralPath $archive -Destination $Path
		} else {
			throw "unexpected fixture URL: $Url"
		}
	}

	$integrationDir = Join-Path $root 'integration-bin'
	$Version = '9.9.10'
	$Dir = $integrationDir
	$Method = 'Binary'
	$NoTools = $true
	$NoPath = $true
	$Force = $false
	$Quiet = $true
	Invoke-Install
	$expectedInstall = Join-Path $integrationDir 'atomscan.exe'
	if ($script:Installed -ne $expectedInstall) { throw "installed at unexpected path $($script:Installed)" }
	if ((Get-InstalledVersion $script:Installed) -ne '9.9.10') { throw 'end-to-end fixture does not run' }
	Write-Host "ok - end-to-end binary install -> $($script:Installed)"

	# Source checkouts are cloned into a unique sibling first. Exercise recovery
	# from a pre-existing non-Git cache and reuse of the promoted checkout.
	$env:LOCALAPPDATA = Join-Path $root 'local-app-data'
	$sourceCache = Join-Path $env:LOCALAPPDATA 'atomdrift\scan-src'
	New-Item -ItemType Directory -Force -Path $sourceCache | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $sourceCache 'interrupted'), "partial`n")
	$script:MockClones = 0
	$script:MockFetches = 0
	$script:MockCheckouts = 0
	$script:MockOrigin = 'https://github.com/atomdrift-project/scan.git'
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
		Copy-Item -LiteralPath $fixtureOne -Destination (Join-Path $mockBuilt 'atomscan.exe') -Force
		$global:LASTEXITCODE = 0
	}
	function rustc {
		Write-Output 'rustc 1.94.0 (test toolchain)'
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
	$env:LOCALAPPDATA = $oldLocalAppData
	Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
