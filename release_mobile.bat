@echo off
setlocal

echo ============================================
echo   Blue Sky Mobile - Release Builder
echo ============================================
echo.

set /p VERSION="Enter new version number (e.g. 1.0.2): "
if "%VERSION%"=="" (
    echo No version entered. Aborting.
    exit /b 1
)

set SCRIPT_DIR=%~dp0
set PUBSPEC=%SCRIPT_DIR%lib\pubspec.yaml
set MAIN_DART=%SCRIPT_DIR%lib\main.dart
set APK=%SCRIPT_DIR%build\app\outputs\flutter-apk\app-release.apk

echo.
echo [1/5] Updating version in pubspec.yaml and main.dart to %VERSION%...
powershell -Command "(Get-Content '%PUBSPEC%') -replace '^version: .*', 'version: %VERSION%+1' | Set-Content '%PUBSPEC%'"
powershell -Command "(Get-Content '%MAIN_DART%') -replace 'const String _appVersion = ''[^'']+''', 'const String _appVersion = ''%VERSION%''' | Set-Content '%MAIN_DART%'"
echo Done.

echo.
echo [2/5] Cleaning previous build...
cd /d "%SCRIPT_DIR%"
flutter clean
echo Done.

echo.
echo [3/5] Building release APK...
flutter build apk --release
if errorlevel 1 (
    echo Flutter build FAILED. Aborting.
    exit /b 1
)
echo Done.

echo.
echo [4/5] Committing and pushing to GitHub...
git add lib\main.dart lib\pubspec.yaml lib\pubspec.lock
git commit -m "Release v%VERSION%"
git push origin master
if errorlevel 1 (
    echo Git push FAILED. Check your connection and try again.
    exit /b 1
)
echo Done.

echo.
echo [5/5] Creating GitHub release and uploading APK...
gh release create "v%VERSION%-mobile" "%APK%#app-release.apk" ^
    --repo blueskysmog1/bluesky-smog-mobile ^
    --title "Blue Sky Mobile v%VERSION%" ^
    --notes "Version %VERSION% - See release for changes." ^
    --latest
if errorlevel 1 (
    echo GitHub release FAILED. The APK was built successfully at:
    echo %APK%
    echo You can upload it manually at: https://github.com/blueskysmog1/bluesky-smog-mobile/releases/new
    exit /b 1
)

echo.
echo ============================================
echo   Release v%VERSION% complete!
echo.
echo   Direct download link:
echo   https://github.com/blueskysmog1/bluesky-smog-mobile/releases/latest/download/app-release.apk
echo ============================================
pause
