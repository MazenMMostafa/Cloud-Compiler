#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/tools"
CLI_PATH="$TOOLS_DIR/arduino-cli"

echo "=========================================="
echo "NewBegin Compiler Server Setup (Linux/macOS)"
echo "=========================================="
echo ""

# ---- Step 1: Download bundled arduino-cli if missing ----
if [ -f "$CLI_PATH" ]; then
    echo "[1/4] Arduino CLI found at $CLI_PATH: OK"
else
    echo "[1/4] Arduino CLI not found. Downloading..."
    mkdir -p "$TOOLS_DIR"

    UNAME_S=$(uname -s)
    if [ "$UNAME_S" = "Linux" ]; then
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64|amd64) URL="https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_64bit.tar.gz" ;;
            aarch64|arm64) URL="https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_ARM64.tar.gz" ;;
            armv7l)        URL="https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Linux_ARMv7.tar.gz" ;;
            *)
                echo "ERROR: Unsupported Linux architecture: $ARCH"
                echo "Manual download: https://arduino.github.io/arduino-cli/installation/"
                exit 1
                ;;
        esac
    elif [ "$UNAME_S" = "Darwin" ]; then
        ARCH=$(uname -m)
        if [ "$ARCH" = "arm64" ]; then
            URL="https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_macOS_ARM64.tar.gz"
        else
            URL="https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_macOS_64bit.tar.gz"
        fi
    else
        echo "ERROR: Unknown OS: $UNAME_S"
        exit 1
    fi

    echo "  Downloading from $URL"
    if command -v curl &> /dev/null; then
        curl -fsSL -o "$TOOLS_DIR/arduino-cli.tar.gz" "$URL" || {
            echo "ERROR: Download failed"
            exit 1
        }
    elif command -v wget &> /dev/null; then
        wget -q -O "$TOOLS_DIR/arduino-cli.tar.gz" "$URL" || {
            echo "ERROR: Download failed"
            exit 1
        }
    else
        echo "ERROR: Neither curl nor wget found. Install one of them first."
        exit 1
    fi

    echo "  Extracting to $TOOLS_DIR..."
    tar -xzf "$TOOLS_DIR/arduino-cli.tar.gz" -C "$TOOLS_DIR"
    rm -f "$TOOLS_DIR/arduino-cli.tar.gz"
    chmod +x "$CLI_PATH"

    if [ -f "$CLI_PATH" ]; then
        echo "  Successfully downloaded to $CLI_PATH"
    else
        echo "ERROR: Extraction failed"
        exit 1
    fi
fi

# ---- Step 2: Update core index ----
echo "[2/4] Updating core index..."
"$CLI_PATH" core update-index

# ---- Step 3: Install cores ----
echo "[3/4] Installing cores (this downloads AVR/ESP32/ESP8266 toolchains)..."
echo "  Installing arduino:avr..."
"$CLI_PATH" core install arduino:avr
echo "  Installing esp32:esp32..."
"$CLI_PATH" core install esp32:esp32
echo "  Installing esp8266:esp8266..."
"$CLI_PATH" core install esp8266:esp8266

# ---- Step 4: Install Dart dependencies ----
echo "[4/4] Installing Dart dependencies..."
cd "$SCRIPT_DIR"
dart pub get

echo ""
echo "=========================================="
echo "Setup complete!"
echo ""
echo "To start the server:"
echo "  dart run bin/server.dart --port 8080"
echo ""
echo "The bundled arduino-cli at $CLI_PATH will be used automatically."
echo "No global installation required."
echo "=========================================="
