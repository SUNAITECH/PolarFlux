#!/bin/zsh

# PolarFlux Pro Build System
# Target: macOS 14.0+ (Universal Binary)
# Bundle ID: com.sunaish.polarflux

set -e
set -u
set -o pipefail
# Reset locale for predictable behavior
export LANG=en_US.UTF-8

# --- Configuration ---
APP_NAME="PolarFlux"
BUNDLE_ID="com.sunaish.polarflux"

# Versioning Logic:
# 1. Direct argument (e.g., ./run.sh build 2026.01.17)
# 2. Environment variable (VERSION=1.2.3 ./run.sh)
# 3. Default (Current Date)
ARG_VERSION="${2:-}"
if [[ "$ARG_VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
    VERSION_STR="$ARG_VERSION"
else
    VERSION_STR="${VERSION:-$(date +%Y.%m.%d)}"
fi

# Safety: Use script location to determine project root
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Safety Checks
if [[ ! -d "$PROJECT_ROOT/Sources/PolarFlux" ]]; then
    echo "Error: Could not find Sources/PolarFlux in $PROJECT_ROOT"
    echo "Please ensure you are running this script from within the project structure."
    exit 1
fi

BUILD_DIR="$PROJECT_ROOT/.build"
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# --- UI Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# --- Helpers ---
log() { echo "${BLUE}==>${NC} ${BOLD}$1${NC}"; }
success() { echo "${GREEN}✔${NC} ${BOLD}$1${NC}"; }
warn() { echo "${YELLOW}⚠${NC} ${BOLD}$1${NC}"; }
error() { echo "${RED}✘${NC} ${BOLD}$1${NC}"; exit 1; }

# Ensure we are in the project root
cd "$PROJECT_ROOT" || error "Could not access project root at $PROJECT_ROOT"

show_help() {
    echo "${BOLD}PolarFlux Build Tool v2.2${NC}"
    echo "Usage: $0 [command] [version]"
    echo ""
    echo "Commands:"
    echo "  build [version]  Create a production-ready Universal App Bundle"
    echo "  run   [version]  Build and launch the application"
    echo "  dmg   [version]  Package the application into DMG"
    echo "  test              Run serial + audio pipeline regression tests"
    echo "  clean            Deep clean build artifacts and system junk"
    echo "  icon             Regenerate high-quality icons from source"
    echo "  help             Show this help menu"
    echo ""
    echo "Example:"
    echo "  $0 build 2026.01.18"
}

check_deps() {
    log "Verifying environment..."
    for tool in swift xcrun lipo hdiutil; do
        if ! command -v $tool >/dev/null; then error "$tool is not installed."; fi
    done
    if ! command -v python3 >/dev/null; then warn "Python3 not found, icon generation might fail."; fi
}

clean() {
    log "Performing deep clean..."
    rm -rf "$BUILD_DIR"
    rm -rf "$APP_BUNDLE"
    find . -name ".DS_Store" -depth -delete
    success "Workspace is clean."
}

generate_icon() {
    log "Generating high-resolution icons..."
    if [ ! -f "Scripts/generate_icon.py" ]; then error "Icon script missing!"; fi
    python3 Scripts/generate_icon.py
    success "Icons updated at Resources/PolarFlux.icns"
}

build() {
    check_deps
    
    # 1. Start with a fresh container
    log "Preparing build environment..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR"

    # Use zsh globbing for safer file handling
    local -a SOURCES
    SOURCES=(Sources/PolarFlux/**/*.swift)
    if [[ ${#SOURCES} -eq 0 ]]; then error "No source files found!"; fi

    SDK_PATH=$(xcrun --show-sdk-path)
    if [[ -z "$SDK_PATH" ]]; then error "Could not find macOS SDK path."; fi
    
    # 2. Optimized Compilation
    log "Starting Universal Build (arm64 + x86_64)..."
    
    local COMMON_FLAGS=(
        -sdk "$SDK_PATH"
        -O
        -whole-module-optimization
        -parse-as-library
        -enforce-exclusivity=checked
    )

    log "Compiling for Apple Silicon..."
    xcrun -sdk macosx swiftc "${SOURCES[@]}" \
        -target arm64-apple-macos14.0 \
        "${COMMON_FLAGS[@]}" \
        -o "$BUILD_DIR/PolarFlux_arm64"

    log "Compiling for Intel..."
    xcrun -sdk macosx swiftc "${SOURCES[@]}" \
        -target x86_64-apple-macos14.0 \
        "${COMMON_FLAGS[@]}" \
        -o "$BUILD_DIR/PolarFlux_x86_64"

    local METAL_EMBEDDED=0
    log "Compiling Metal Shaders (default.metallib)..."
    # Explicitly verify metal toolchain presence
    if command -v metal >/dev/null 2>&1 || xcrun -sdk macosx --find metal >/dev/null 2>&1; then
        # Try compiling with xcrun -sdk macosx. If that fails, embed the shader
        # source instead so MetalProcessor can runtime-compile it (GPU stays
        # active either way — a CPU-fallback build must NEVER ship silently).
        if xcrun -sdk macosx metal -c Sources/PolarFlux/Metal/Shaders.metal -o "$BUILD_DIR/Shaders.air" 2>"$BUILD_DIR/metal_error.log"; then
            xcrun -sdk macosx metallib "$BUILD_DIR/Shaders.air" -o "$RESOURCES_DIR/default.metallib"
            METAL_EMBEDDED=1
            success "Metal shaders compiled successfully."
        else
            warn "Metal compilation failed ($(tail -1 "$BUILD_DIR/metal_error.log" 2>/dev/null))."
            cp Sources/PolarFlux/Metal/Shaders.metal "$RESOURCES_DIR/Shaders.metal"
            METAL_EMBEDDED=1
            warn "Embedded Shaders.metal source instead — app will runtime-compile the kernel (GPU active)."
            warn "Fix locally with: xcodebuild -downloadComponent MetalToolchain"
        fi
    else
        warn "Metal compiler not found! (Detailed: xcrun metal failed)"
        cp Sources/PolarFlux/Metal/Shaders.metal "$RESOURCES_DIR/Shaders.metal"
        METAL_EMBEDDED=1
        warn "Embedded Shaders.metal source instead — app will runtime-compile the kernel (GPU active)."
    fi

    if [[ "$METAL_EMBEDDED" -ne 1 ]]; then
        error "Metal GPU resources missing — refusing to produce a CPU-fallback build."
    fi

    log "Stitching Universal Binary (Lipo)..."
    lipo -create "$BUILD_DIR/PolarFlux_arm64" "$BUILD_DIR/PolarFlux_x86_64" -output "$MACOS_DIR/$APP_NAME"

    # 3. Packaging and Resource Hygiene
    log "Packaging resources..."
    if [ -f "Resources/Info.plist" ]; then
        cp Resources/Info.plist "$CONTENTS_DIR/"
        plutil -replace CFBundleShortVersionString -string "$VERSION_STR" "$CONTENTS_DIR/Info.plist"
        plutil -replace CFBundleVersion -string "$(date +%Y%m%d.%H%M)" "$CONTENTS_DIR/Info.plist"
        plutil -replace CFBundleName -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
        plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
    else
        error "Info.plist missing from Resources/"
    fi

    if [ -f "Resources/PolarFlux.icns" ]; then
        cp Resources/PolarFlux.icns "$RESOURCES_DIR/"
    else
        warn "Icon missing, app will have default icon."
    fi

    # Critical guarantee: the shipped app MUST contain a Metal kernel
    # (compiled metallib or runtime-compilable source). Without either, the
    # vision engine silently degrades to the CPU path.
    if [[ ! -f "$RESOURCES_DIR/default.metallib" && ! -f "$RESOURCES_DIR/Shaders.metal" ]]; then
        error "GPU kernel missing from bundle — refusing to ship a CPU-fallback build."
    fi

    # Copy localizations while stripping .DS_Store
    for lproj in Resources/*.lproj; do
        if [ -d "$lproj" ]; then
            dest="$RESOURCES_DIR/$(basename "$lproj")"
            mkdir -p "$dest"
            # Using rsync to copy only content, avoiding hidden files and metadata
            rsync -a --exclude=".*" "$lproj/" "$dest/"
        fi
    done

    # 4. Critical Robustness: Cleaning and Signing
    log "Applying enterprise-grade resource hygiene..."
    
    # Remove all extended attributes recursively from the bundle
    # This is critical for codesigning to succeed
    /usr/bin/find "$APP_BUNDLE" -print0 | xargs -0 xattr -c 2>/dev/null || true
    /usr/bin/find "$APP_BUNDLE" -name ".DS_Store" -delete || true
    
    if command -v dot_clean >/dev/null; then
        dot_clean -m "$APP_BUNDLE" || true
    fi
    
    log "Applying Ad-hoc signature..."
    # Always sign with --force and --deep to ensure entire bundle is covered
    # --options=runtime is best practice for modern macOS security
    codesign --verbose --force --deep --sign - --options=runtime "$APP_BUNDLE"

    # Verification
    if codesign --verify --verbose --deep "$APP_BUNDLE"; then
        success "PolarFlux.app is ready and verified (Universal Binary)."
    else
        error "Codesign verification failed."
    fi
}

dmg() {
    build
    log "Packaging into Modern DMG..."
    
    DMG_NAME="${APP_NAME}_v${VERSION_STR}.dmg"
    DMG_PATH="$PROJECT_ROOT/$DMG_NAME"
    TEMP_DMG="$BUILD_DIR/temp.dmg"
    # Allow system to handle mount point to ensure Finder works correctly
    VOL_NAME="${APP_NAME}"
    
    # Use global variables so the EXIT trap can access them after dmg() returns
    DEV_NODE=""
    MOUNT_POINT=""
    
    cleanup_dmg() {
        if [[ -n "${DEV_NODE:-}" ]]; then
            if hdiutil info | grep -q "$DEV_NODE"; then
                log "Cleaning up device..."
                hdiutil detach "$DEV_NODE" -force >/dev/null 2>&1 || true
            fi
        elif [[ -n "${MOUNT_POINT:-}" ]]; then
            if mount | grep -q "$MOUNT_POINT"; then
                 log "Cleaning up mount point..."
                 hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
            fi
        fi
        rm -f "${TEMP_DMG:-}"
    }
    trap cleanup_dmg EXIT
    
    rm -f "$DMG_PATH" "$TEMP_DMG"
    
    APP_SIZE=$(du -sm "$APP_BUNDLE" | cut -f1)
    DMG_SIZE=$((APP_SIZE + 30))
    log "Creating ${DMG_SIZE}MB temporary disk..."
    hdiutil create -size "${DMG_SIZE}m" -fs HFS+ -volname "$VOL_NAME" "$TEMP_DMG" -quiet
    
    log "Mounting temporary disk..."
    # Attach without custom mountpoint to let macOS mount it to /Volumes (Better for Finder scripting)
    ATTACH_OUTPUT=$(hdiutil attach "$TEMP_DMG" -noautoopen)
    
    # Parse Output
    # Expected format: /dev/diskXsY   Apple_HFS   /Volumes/VolumeName
    DEV_NODE=$(echo "$ATTACH_OUTPUT" | grep -o '/dev/disk[0-9]*' | head -n 1)
    MOUNT_POINT=$(echo "$ATTACH_OUTPUT" | grep "/Volumes/" | awk '{$1=""; $2=""; print $0}' | xargs)
    
    if [[ -z "$DEV_NODE" || -z "$MOUNT_POINT" ]]; then
        # Fallback parsing strategy
        MOUNT_POINT="/Volumes/$VOL_NAME"
        if [[ -z "$DEV_NODE" ]]; then
           error "Failed to determine device node from hdiutil output."
        fi
    fi
    
    log "Mounted at: $MOUNT_POINT"

    log "Copying application bundle..."
    cp -R "$APP_BUNDLE" "$MOUNT_POINT/"
    ln -s /Applications "$MOUNT_POINT/Applications"
    
    # Ensure filesystem is synced before Finder styling
    sync
    sleep 2

    # Advanced Styling
    if [[ "$CI" != "true" && "$GITHUB_ACTIONS" != "true" ]] && pgrep -x "Finder" > /dev/null; then
        log "Applying modern styling (AppleScript)..."
        
        if osascript >/dev/null 2>&1 <<EOF
            tell application "Finder"
                try
                    -- Use the Volume Name directly as it is now in /Volumes
                    set target_disk to disk "$VOL_NAME"
                    
                    tell target_disk
                        open
                        set current view of container window to icon view
                        set toolbar visible of container window to false
                        set statusbar visible of container window to false
                        set the bounds of container window to {400, 100, 1000, 500}
                        set viewOptions to the icon view options of container window
                        set icon size of viewOptions to 144
                        set text size of viewOptions to 12
                        set arrangement of viewOptions to not arranged
                        set background picture of viewOptions to none
                        
                        set position of item "$APP_NAME.app" of container window to {180, 180}
                        set position of item "Applications" of container window to {420, 180}
                        
                        -- Force update and save
                        update without registering applications
                        delay 2
                        close
                    end tell
                    
                    -- Second pass to ensure icons stick (AppleScript quirk)
                    delay 1
                    tell target_disk
                        open
                        set arrangement of viewOptions to not arranged
                        update without registering applications
                        delay 1
                        close
                    end tell

                on error errStr
                    error errStr
                end try
            end tell
EOF
        then
            success "Styling applied successfully."
        else
            warn "Finder styling failed, proceeding with default layout."
        fi
    else
        log "Styling skipped (CI or Finder missing)."
    fi

    log "Finalizing DMG..."
    sync
    # Fix permissions
    chmod -Rf go-w "$MOUNT_POINT" || true
    
    log "Detaching disk..."
    for i in {1..10}; do
        # Ejecting via diskutil is sometimes cleaner for Finder than hdiutil detach
        if hdiutil detach "$DEV_NODE" -force -quiet; then
            break
        fi
        log "Disk busy, retrying detach ($i/10)..."
        sleep 1
    done
    
    log "Compressing DMG..."
    hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -quiet
    
    success "Modern package created: $DMG_NAME"
}

run() {
    build
    log "Launching application..."
    open "$APP_BUNDLE"
}

test_serial() {
    log "Running serial concurrency stress test..."
    local TEST_BIN="$BUILD_DIR/SerialStressTest"
    # Top-level code must live in a file literally named main.swift.
    mkdir -p "$BUILD_DIR/stress"
    cp Scripts/SerialStressTest.swift "$BUILD_DIR/stress/main.swift"
    xcrun -sdk macosx swiftc -O \
        Sources/PolarFlux/SerialPort.swift \
        Sources/PolarFlux/Logger.swift \
        "$BUILD_DIR/stress/main.swift" \
        -o "$TEST_BIN" || error "Stress test failed to compile."
    "$TEST_BIN" || error "Serial stress test FAILED — deadlock or lost completions detected."
    success "Serial stress test passed."
}

test_audio() {
    log "Running audio DSP pipeline test..."
    local TEST_BIN="$BUILD_DIR/AudioPipelineTest"
    mkdir -p "$BUILD_DIR/audiotest"
    cp Scripts/AudioPipelineTest.swift "$BUILD_DIR/audiotest/main.swift"
    xcrun -sdk macosx swiftc -O \
        Sources/PolarFlux/AudioProcessor.swift \
        Sources/PolarFlux/SystemAudioCapture.swift \
        Sources/PolarFlux/Logger.swift \
        "$BUILD_DIR/audiotest/main.swift" \
        -o "$TEST_BIN" || error "Audio pipeline test failed to compile."
    "$TEST_BIN" || error "Audio pipeline test FAILED — Music-mode DSP chain broken."
    success "Audio pipeline test passed."
}

run_tests() {
    test_serial
    test_audio
}

case "${1:-build}" in
    build) build ;;
    run)   run ;;
    dmg)   dmg ;;
    clean) clean ;;
    icon)  generate_icon ;;
    test)  run_tests ;;
    help)  show_help ;;
    *)     error "Unknown command: $1. Use '$0 help' for usage." ;;
esac
