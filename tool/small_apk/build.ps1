# Builds one universal release APK, recompresses it without dropping features,
# then aligns and signs it with the existing release certificate.
#
#   powershell -ExecutionPolicy Bypass -File tool\small_apk\build.ps1 [-Output path]
param(
  [string]$Output = 'build\nexMusic.apk',
  [int]$Iterations = 5
)

$tool = $PSScriptRoot
Set-Location (Resolve-Path (Join-Path $tool '..\..') -ErrorAction Stop)

flutter build apk --release --target-platform android-arm,android-arm64,android-x64 --obfuscate --split-debug-info=build\symbols --extra-gen-snapshot-options=--strip
if ($LASTEXITCODE -ne 0) { throw 'flutter build failed' }

if (-not (Test-Path "$tool\node_modules\@gfx\zopfli")) {
  npm ci --prefix $tool --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
}

$work = 'build\small_apk'
New-Item -ItemType Directory -Force $work | Out-Null
node "$tool\repack-apk.cjs" 'build\app\outputs\flutter-apk\app-release.apk' "$work\unsigned.apk" $Iterations
if ($LASTEXITCODE -ne 0) { throw 'repack failed' }

node "$tool\sign-release.cjs" "$work\unsigned.apk" $Output
if ($LASTEXITCODE -ne 0) { throw 'apksigner failed' }

$bytes = (Get-Item $Output).Length
'{0}: {1:N0} bytes ({2:N2} MB)' -f $Output, $bytes, ($bytes / 1e6)
