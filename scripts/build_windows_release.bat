@echo off
rem ==============================================================================
rem CodeLiteX - Windows Release & Packaging Script (Phase 11.1)
rem ==============================================================================

setlocal enabledelayedexpansion

set SCRIPT_DIR=%~dp0
set WORKSPACE_ROOT=%SCRIPT_DIR%..
set DIST_DIR=%WORKSPACE_ROOT%\dist\release\windows
set STANDALONE_DIR=%DIST_DIR%\CodeLiteX-windows-x64

echo ================================================================================
echo           CodeLiteX Windows Release Packaging
echo ================================================================================

if not exist "%DIST_DIR%" mkdir "%DIST_DIR%"
if not exist "%STANDALONE_DIR%" mkdir "%STANDALONE_DIR%"

echo [1/3] Building Rust Core (codelite.dll and code-lite-app.exe)...
cd /d "%WORKSPACE_ROOT%"
cargo build --release --offline -p code-lite-ffi
if errorlevel 1 (
    echo Error building code-lite-ffi!
    exit /b 1
)

cargo build --release --offline -p code-lite-app
if errorlevel 1 (
    echo Error building code-lite-app!
    exit /b 1
)

echo [2/3] Staging Windows Release artifacts...
copy /y "%WORKSPACE_ROOT%\target\release\codelite.dll" "%STANDALONE_DIR%\" >nul
copy /y "%WORKSPACE_ROOT%\target\release\code-lite-app.exe" "%STANDALONE_DIR%\" >nul

echo [3/3] Generating portable ZIP package...
powershell -Command "Compress-Archive -Path '%STANDALONE_DIR%\*' -DestinationPath '%DIST_DIR%\CodeLiteX-windows-x64.zip' -Force"

echo.
echo ================================================================================
echo Windows Release packaging completed in: %DIST_DIR%
echo ================================================================================
