#!/bin/bash
# build.sh — Compile pkgserver Java sources into a single classes.dex
#
# Requirements:
#   - Android SDK with build-tools (e.g. 33.0.0)
#   - ANDROID_HOME or ANDROID_SDK_ROOT set, OR set SDK_DIR below
#   - android.jar on classpath (provided by SDK)
#
# Usage:
#   chmod +x build.sh
#   ./build.sh
#
# Output:
#   out/classes.dex  — copy this to CableBee/assets/pkgserver.dex

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
OUT_DIR="$SCRIPT_DIR/out"
BUILD_TOOLS_VERSION="33.0.0"

# ── Locate Android SDK ────────────────────────────────────────────────────────
SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [ ! -d "$SDK_DIR" ]; then
    # Try common locations
    for candidate in \
        "$HOME/Android/Sdk" \
        "/usr/local/lib/android/sdk" \
        "/opt/android-sdk"; do
        if [ -d "$candidate" ]; then
            SDK_DIR="$candidate"
            break
        fi
    done
fi

if [ ! -d "$SDK_DIR" ]; then
    echo "ERROR: Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT."
    exit 1
fi
echo "Using SDK: $SDK_DIR"

# ── Find build-tools ──────────────────────────────────────────────────────────
BT_DIR="$SDK_DIR/build-tools/$BUILD_TOOLS_VERSION"
if [ ! -d "$BT_DIR" ]; then
    # Use whatever version is available
    BT_DIR=$(ls -d "$SDK_DIR/build-tools/"*/ 2>/dev/null | sort -V | tail -1)
    BT_DIR="${BT_DIR%/}"
fi
if [ ! -d "$BT_DIR" ]; then
    echo "ERROR: No build-tools found in $SDK_DIR/build-tools/"
    exit 1
fi
echo "Using build-tools: $BT_DIR"

# ── Find android.jar ──────────────────────────────────────────────────────────
ANDROID_JAR=$(find "$SDK_DIR/platforms" -name "android.jar" 2>/dev/null | sort -V | tail -1)
if [ -z "$ANDROID_JAR" ]; then
    echo "ERROR: android.jar not found in $SDK_DIR/platforms/"
    exit 1
fi
echo "Using android.jar: $ANDROID_JAR"

# ── Find d8 (preferred) or dx ─────────────────────────────────────────────────
D8="$BT_DIR/d8"
DX="$BT_DIR/dx"
if [ -f "$D8" ]; then
    DEX_TOOL="d8"
elif [ -f "$DX" ]; then
    DEX_TOOL="dx"
else
    echo "ERROR: Neither d8 nor dx found in $BT_DIR"
    exit 1
fi
echo "Using dex tool: $DEX_TOOL ($BT_DIR)"

# ── Prepare output dirs ───────────────────────────────────────────────────────
CLASS_DIR="$OUT_DIR/classes"
rm -rf "$CLASS_DIR"
mkdir -p "$CLASS_DIR"
mkdir -p "$OUT_DIR"

# ── Collect Java sources ──────────────────────────────────────────────────────
SOURCES=$(find "$SRC_DIR" -name "*.java" | tr '\n' ' ')
echo "Sources: $SOURCES"

# ── Compile ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Compiling Java sources ==="
javac \
    -source 8 -target 8 \
    -bootclasspath "$ANDROID_JAR" \
    -classpath "$ANDROID_JAR" \
    -d "$CLASS_DIR" \
    $SOURCES

echo "Compiled .class files:"
find "$CLASS_DIR" -name "*.class" | sort

# ── Dex ───────────────────────────────────────────────────────────────────────
echo ""
echo "=== Converting to DEX ==="
CLASS_FILES=$(find "$CLASS_DIR" -name "*.class" | tr '\n' ' ')

if [ "$DEX_TOOL" = "d8" ]; then
    "$D8" \
        --release \
        --min-api 21 \
        --output "$OUT_DIR" \
        $CLASS_FILES
else
    "$DX" \
        --dex \
        --min-sdk-version=21 \
        --output="$OUT_DIR/classes.dex" \
        "$CLASS_DIR"
fi

if [ -f "$OUT_DIR/classes.dex" ]; then
    SIZE=$(wc -c < "$OUT_DIR/classes.dex")
    echo ""
    echo "=== SUCCESS ==="
    echo "Output: $OUT_DIR/classes.dex ($SIZE bytes)"
    echo ""
    echo "Next step: copy to CableBee Flutter project"
    echo "  cp $OUT_DIR/classes.dex <CableBee>/assets/pkgserver.dex"
else
    echo "ERROR: classes.dex not created"
    exit 1
fi
