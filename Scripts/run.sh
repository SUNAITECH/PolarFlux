#!/bin/zsh

# PolarFlux Pro Build System
# Target: macOS 14.0+ (Universal Binary)
# Bundle ID: com.sunaish.polarflux

set -e
set -o pipefail
# Reset locale for predictable behavior
export LANG=en_US.UTF-8

# --- Configuration ---
APP_NAME="PolarFlux"
BUNDLE_ID="com.sunaish.polarflux"
VERSION_STR="${VERSION:-$(date +%Y.%m.%d)}"

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
    echo "${BOLD}PolarFlux Build Tool v2.1${NC}"
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  build       Create a production-ready Universal App Bundle"
    echo "  run         Build and launch the application"
    echo "  dmg         Package the application into DMG"
    echo "  clean       Deep clean build artifacts and system junk"
    echo "  icon        Regenerate high-quality icons from source"
    echo "  help        Show this help menu"
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
    log "Starting Universal Build (arm64 + x86_64)..."

    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR"

    # Use zsh globbing for safer file handling
    local -a SOURCES
    SOURCES=(Sources/PolarFlux/**/*.swift)
    if [[ ${#SOURCES} -eq 0 ]]; then error "No source files found!"; fi

    SDK_PATH=$(xcrun --show-sdk-path)
    if [[ -z "$SDK_PATH" ]]; then error "Could not find macOS SDK path."; fi
    
    log "Compiling for Apple Silicon..."
    xcrun -sdk macosx swiftc "${SOURCES[@]}" \
        -target arm64-apple-macos14.0 \
        -sdk "$SDK_PATH" \
        -o "$BUILD_DIR/PolarFlux_arm64" \
        -O -whole-module-optimization \
        -parse-as-library

    log "Compiling for Intel..."
    xcrun -sdk macosx swiftc "${SOURCES[@]}" \
        -target x86_64-apple-macos14.0 \
        -sdk "$SDK_PATH" \
        -o "$BUILD_DIR/PolarFlux_x86_64" \
        -O -whole-module-optimization \
        -parse-as-library

    log "Stitching Universal Binary (Lipo)..."
    lipo -create "$BUILD_DIR/PolarFlux_arm64" "$BUILD_DIR/PolarFlux_x86_64" -output "$MACOS_DIR/$APP_NAME"

    log "Packaging resources..."
    if [ -f "Resources/Info.plist" ]; then
        cp Resources/Info.plist "$CONTENTS_DIR/"
        plutil -replace CFBundleShortVersionString -string "$VERSION_STR" "$CONTENTS_DIR/Info.plist"
        plutil -replace CFBundleVersion -string "$(date +%Y%m%d.%H%M)" "$CONTENTS_DIR/Info.plist"
    else
        error "Info.plist missing from Resources/"
    fi

    if [ -f "Resources/PolarFlux.icns" ]; then
        cp Resources/PolarFlux.icns "$RESOURCES_DIR/"
    else
        warn "Icon missing, app will have default icon."
    fi

    find Resources -name "*.lproj" -type d -exec cp -R {} "$RESOURCES_DIR/" \;

    log "Cleaning resource forks and Finder info..."
    xattr -cr "$APP_BUNDLE" || true
    if command -v dot_clean >/dev/null; then
        dot_clean -m "$APP_BUNDLE" || true
    fi
    
    log "Applying Ad-hoc signature..."
    codesign --force --deep --sign - "$APP_BUNDLE"

    success "PolarFlux.app is ready (Universal Binary)."
}

dmg() {
    build
    log "Packaging into Modern DMG..."
    
    DMG_NAME="${APP_NAME}_v${VERSION_STR}.dmg"
    DMG_PATH="$PROJECT_ROOT/$DMG_NAME"
    TEMP_DMG="$BUILD_DIR/temp.dmg"
    MOUNT_POINT="$BUILD_DIR/mnt"
    VOL_NAME="${APP_NAME}"
    
    cleanup_dmg() {
        if mount | grep -q "$MOUNT_POINT"; then
            log "Cleaning up mount point..."
            hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
        fi
        rm -f "$TEMP_DMG"
        rm -rf "$MOUNT_POINT"
    }
    trap cleanup_dmg EXIT
    
    rm -f "$DMG_PATH" "$TEMP_DMG"
    mkdir -p "$MOUNT_POINT"
    
    APP_SIZE=$(du -sm "$APP_BUNDLE" | cut -f1)
    DMG_SIZE=$((APP_SIZE + 30))
    log "Creating ${DMG_SIZE}MB temporary disk..."
    hdiutil create -size "${DMG_SIZE}m" -fs HFS+ -volname "$VOL_NAME" "$TEMP_DMG" -quiet
    
    log "Mounting temporary disk..."
    # 'attach' returns the device node
    # Use || true to prevent grep exit code from killing the script if pipefail is on
    # However, we really want to capture duplicate output.
    # Let's verify hdiutil output first. 
    # "hdiutil attach ... -quiet" might output nothing if quiet is too aggressive, but usually outputs /dev/disk...
    # We remove -quiet to see output, capture it, then parse.
    
    ATTACH_OUTPUT=$(hdiutil attach "$TEMP_DMG" -noautoopen -mountpoint "$MOUNT_POINT")
    DEV_NODE=$(echo "$ATTACH_OUTPUT" | grep -o '/dev/disk[0-9]*' | head -n 1)
    
    if [[ -z "$DEV_NODE" ]]; then
        error "Failed to mount DMG or determine device node."
    fi

    log "Copying application bundle..."
    cp -R "$APP_BUNDLE" "$MOUNT_POINT/"
    ln -s /Applications "$MOUNT_POINT/Applications"
    
    # Ensure filesystem is synced before Finder styling
    sync
    sleep 1

    # Advanced Styling
    if [[ "$CI" != "true" && "$GITHUB_ACTIONS" != "true" ]] && pgrep -x "Finder" > /dev/null; then
        log "Applying modern styling (AppleScript)..."
        
        # We use the mount point path directly to find the disk in Finder.
        # This is more robust than searching by name.
        if osascript >/dev/null 2>&1 <<EOF
            tell application "Finder"
                try
                    set disk_alias to (POSIX file "$MOUNT_POINT") as alias
                    set disk_name to name of disk_alias
                    
                    tell disk disk_name
                        open
                        set current view of container window to icon view
                        set toolbar visible of container window to false
                        set statusbar visible of container window to false
                        set the bounds of container window to {400, 100, 1000, 500}
                        set viewOptions to the icon view options of container window
                        set icon size of viewOptions to 128
                        set arrangement of viewOptions to not arranged
                        set position of item "$APP_NAME.app" of container window to {180, 180}
                        set position of item "Applications" of container window to {420, 180}
                        
                        update without registering applications
                        delay 2
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
    chmod -Rf go-w "$MOUNT_POINT" || true
    
    # Robust detach with explicit device node if available, otherwise mount point
    log "Detaching disk..."
    local DETACH_TARGET="${DEV_NODE:-$MOUNT_POINT}"
    for i in {1..10}; do
        if hdiutil detach "$DETACH_TARGET" -force -quiet; then
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

case "${1:-build}" in
    build) build ;;
    run)   run ;;
    dmg)   dmg ;;
    clean) clean ;;
    icon)  generate_icon ;;
    help)  show_help ;;
    *)     error "Unknown command: $1. Use '$0 help' for usage." ;;
esac
