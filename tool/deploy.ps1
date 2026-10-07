$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

if (-not (Test-Path "env\dev.json")) {
    Write-Host "env\dev.json not found." -ForegroundColor Red
    exit 1
}

Write-Host "1/2  Building the app (2-4 minutes)..." -ForegroundColor Cyan
flutter build web --release --dart-define-from-file=env/dev.json
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed." -ForegroundColor Red; exit 1 }

Write-Host "2/2  Publishing..." -ForegroundColor Cyan
if (Get-Command npx -ErrorAction SilentlyContinue) {
    npx --yes netlify-cli deploy --prod --dir "build/web"
    Write-Host "Done." -ForegroundColor Green
} else {
    Write-Host "Drag the build\web folder into app.netlify.com/drop" -ForegroundColor Yellow
    Start-Process explorer.exe (Resolve-Path "build").Path
    Start-Process "https://app.netlify.com/drop"
}