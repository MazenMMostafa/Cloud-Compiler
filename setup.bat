@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "TOOLS_DIR=%SCRIPT_DIR%tools"
set "CLI_PATH=%TOOLS_DIR%\arduino-cli.exe"

echo ==========================================
echo NewBegin Compiler Server Setup (Windows)
echo ==========================================
echo.

REM ---- Step 1: Download bundled arduino-cli if missing ----
if exist "%CLI_PATH%" (
    echo [1/4] Arduino CLI found at tools\arduino-cli.exe: OK
) else (
    echo [1/4] Arduino CLI not found. Downloading...
    if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%"

    set "ZIP_PATH=%TOOLS_DIR%\arduino-cli.zip"
    set "URL=https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Windows_64bit.zip"

    echo   Downloading from %URL%
    powershell -Command "try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}; Invoke-WebRequest -Uri '%URL%' -OutFile '%ZIP_PATH%' -UseBasicParsing"
    if !ERRORLEVEL! NEQ 0 (
        echo   ERROR: Download failed. Check your internet connection.
        echo   Manual download: %URL%
        echo   Extract the zip into: %TOOLS_DIR%
        pause
        exit /b 1
    )

    echo   Extracting to %TOOLS_DIR%...
    powershell -Command "Expand-Archive -Path '%ZIP_PATH%' -DestinationPath '%TOOLS_DIR%' -Force"
    del "%ZIP_PATH%" 2>nul

    if exist "%CLI_PATH%" (
        echo   Successfully downloaded to %CLI_PATH%
    ) else (
        echo   ERROR: Extraction failed. Expected arduino-cli.exe in the zip root.
        pause
        exit /b 1
    )
)

REM ---- Step 2: Update core index ----
echo [2/4] Updating core index...
"%CLI_PATH%" core update-index

REM ---- Step 3: Install cores ----
echo [3/4] Installing cores (this downloads AVR/ESP32/ESP8266 toolchains)...
echo   Installing arduino:avr...
"%CLI_PATH%" core install arduino:avr
echo   Installing esp32:esp32...
"%CLI_PATH%" core install esp32:esp32
echo   Installing esp8266:esp8266...
"%CLI_PATH%" core install esp8266:esp8266

REM ---- Step 4: Install Dart dependencies ----
echo [4/4] Installing Dart dependencies...
cd /d "%SCRIPT_DIR%"
dart pub get

echo.
echo ==========================================
echo Setup complete!
echo.
echo To start the server:
echo   dart run bin\server.dart --port 8080
echo.
echo The bundled arduino-cli at tools\arduino-cli.exe will be used automatically.
echo No global installation required.
echo ==========================================
pause
