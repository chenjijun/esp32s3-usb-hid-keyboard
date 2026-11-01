@echo off
REM ===========================================================================
REM  Build the Windows client of the ESP32-S3 wireless keyboard bridge.
REM
REM  Output:
REM    dist_win\ESP32Keyboard\ESP32Keyboard.exe   (run this)
REM    dist\ESP32Keyboard-Python-<ver>-win64.zip  (what you hand out)
REM
REM  Keep this file ASCII-only: CMD parses .bat in the OEM code page (GBK),
REM  non-ASCII text here turns into mojibake and sometimes breaks parsing.
REM
REM  Usage:  double-click, or run  build_win.bat  in a terminal.
REM ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "VERSION=1.2.1"
set "ROOT=%~dp0.."
set "VENV=%~dp0.build\win-venv"
set "APPNAME=ESP32Keyboard"
set "ZIP=%ROOT%\dist\%APPNAME%-Python-%VERSION%-win64.zip"

echo === 1/6  find Python ===
set "PYCMD="
where py >nul 2>nul && set "PYCMD=py -3"
if not defined PYCMD (
    where python >nul 2>nul && set "PYCMD=python"
)
if not defined PYCMD (
    echo Python 3 not found. Install it from https://www.python.org/downloads/
    echo and tick "Add python.exe to PATH", then run this script again.
    exit /b 1
)
%PYCMD% --version
if errorlevel 1 exit /b 1

echo === 2/6  create virtual env ===
if not exist "%VENV%\Scripts\python.exe" (
    %PYCMD% -m venv "%VENV%"
    if errorlevel 1 (
        echo Failed to create venv at %VENV%
        exit /b 1
    )
)
set "VPY=%VENV%\Scripts\python.exe"

echo === 3/6  install dependencies ===
"%VPY%" -m pip install --upgrade pip --quiet
"%VPY%" -m pip install --quiet -r "%~dp0requirements.txt"
if errorlevel 1 (
    echo Failed to install requirements.
    exit /b 1
)
"%VPY%" -m pip install --quiet pyinstaller
if errorlevel 1 (
    echo Failed to install pyinstaller.
    exit /b 1
)

echo === 4/6  freeze the GUI ===
REM bleak talks to WinRT; those modules are imported lazily inside bleak, so make
REM sure they are collected whether or not the analysis sees them.
set "EXTRA="
if exist "%VENV%\Lib\site-packages\winrt" set "EXTRA=--collect-submodules winrt"

"%VPY%" -m PyInstaller --noconfirm --clean --windowed ^
    --name "%APPNAME%" ^
    --icon "%ROOT%\app_icon.ico" ^
    --add-data "%ROOT%\app_icon.ico;." ^
    --add-data "%ROOT%\app_icon_256.png;." ^
    --collect-submodules bleak ^
    %EXTRA% ^
    --distpath "%~dp0..\dist_win" ^
    --workpath "%~dp0.build\pyinstaller" ^
    --specpath "%~dp0.build" ^
    "%~dp0ble_keyboard_client.py"
if errorlevel 1 (
    echo PyInstaller failed.
    exit /b 1
)

echo === 5/6  assemble release folder ===
set "STAGE=%ROOT%\dist\%APPNAME%-Python-%VERSION%-win64"
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%" 2>nul
xcopy "%ROOT%\dist_win\%APPNAME%" "%STAGE%\%APPNAME%\" /e /i /q /y >nul
if errorlevel 1 (
    echo Failed to copy the built app.
    exit /b 1
)
copy /y "%~dp0windows\README.txt" "%STAGE%\README.txt" >nul
copy /y "%~dp0ble_keyboard_client.py" "%STAGE%\ble_keyboard_client.py" >nul
copy /y "%~dp0requirements.txt" "%STAGE%\requirements.txt" >nul
copy /y "%~dp0build_win.bat" "%STAGE%\build_win.bat" >nul

echo === 6/6  zip ===
if not exist "%ROOT%\dist" mkdir "%ROOT%\dist"
if exist "%ZIP%" del /q "%ZIP%"
powershell -NoProfile -Command "Compress-Archive -Path '%STAGE%' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (
    echo Failed to create the zip.
    exit /b 1
)
rmdir /s /q "%STAGE%"

echo.
echo Done: %ZIP%
echo Run:  dist_win\%APPNAME%\%APPNAME%.exe
endlocal
