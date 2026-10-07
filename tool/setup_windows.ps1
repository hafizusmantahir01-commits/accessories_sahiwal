# Accessories Sahiwal — one-time setup on Windows (PowerShell).
# Run from the project folder:   powershell -ExecutionPolicy Bypass -File tool\setup_windows.ps1
# Creates the android/ folder (web/ is already included), adds the Internet
# permission for phones, and downloads packages. Existing code is not overwritten.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

flutter create . --platforms=android,web --org pk.accessoriessahiwal --project-name accessories_sahiwal

$manifest = "android\app\src\main\AndroidManifest.xml"
$xml = Get-Content $manifest -Raw
if ($xml -notmatch "android.permission.INTERNET") {
    $xml = $xml -replace "(\s*)<application", "`n    <uses-permission android:name=`"android.permission.INTERNET`"/>`$1<application"
    Write-Host "Added INTERNET permission to $manifest"
}
$xml = $xml -replace 'android:label="accessories_sahiwal"', 'android:label="Accessories Sahiwal"'
[System.IO.File]::WriteAllText((Resolve-Path $manifest).Path, $xml)  # UTF-8 without BOM

# flutter create adds a counter-app sample test that does not apply here.
if ((Test-Path "test\widget_test.dart") -and (Select-String -Path "test\widget_test.dart" -Pattern "MyApp" -Quiet)) {
    Remove-Item "test\widget_test.dart"
}

if (-not (Test-Path "env\dev.json")) { Copy-Item "env\example.json" "env\dev.json" }

flutter pub get
Write-Host ""
Write-Host "Done. Put your Supabase URL and anon key in env\dev.json, then press F5 in VS Code"
Write-Host "or run:  flutter run -d chrome --dart-define-from-file=env/dev.json"
