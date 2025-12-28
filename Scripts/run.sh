#!/bin/zsh

# PolarFlux Pro Build System
# Target: macOS 14.0+ (Universal Binary)
# Bundle ID: com.sunaish.polarflux

set -e

# --- Configuration ---
APP_NAME="PolarFlux"
BUNDLE_ID="com.sunaish.polarflux"

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
log() { echo -e "${BLUE}==>${NC} ${BOLD}$1${NC}"; }
success() { echo -e "${GREEN}✔${NC} ${BOLD}$1${NC}"; }
warn() { echo -e "${YELLOW}⚠${NC} ${BOLD}$1${NC}"; }
error() { echo -e "${RED}✘${NC} ${BOLD}$1${NC}"; exit 1; }

# Ensure we are in the project root
cd "$PROJECT_ROOT" || error "Could not access project root at $PROJECT_ROOT"

show_help() {
    echo -e "${BOLD}PolarFlux Build Tool v2.0${NC}"
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
    # Check for Swift
    if ! command -v swift >/dev/null; then error "Swift is not installed."; fi
    # Check for Python (for icons)
    if ! command -v python3 >/dev/null; then warn "Python3 not found, icon generation might fail."; fi
}

clean() {
    log "Performing deep clean..."
    rm -rf "$BUILD_DIR"
    rm -rf "$APP_BUNDLE"
    find . -name ".DS_Store" -depth -exec rm {} \;
    success "Workspace is clean."
}

generate_icon() {
    log "Generating high-resolution icons..."
    if [ ! -f "Scripts/generate_icon.py" ]; then error "Icon script missing!"; fi
    python3 Scripts/generate_icon.py
    # The python script now handles iconutil and cleanup
    success "Icons updated at Resources/PolarFlux.icns"
}

build() {
    check_deps
    log "Starting Universal Build (arm64 + x86_64)..."

    # 1. Prepare Structure
    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
    mkdir -p "$BUILD_DIR"

    # 2. Find Sources
    # Use zsh globbing for safer file handling
    local -a SOURCES
    SOURCES=(Sources/PolarFlux/**/*.swift)
    if [[ ${#SOURCES} -eq 0 ]]; then error "No source files found!"; fi

    # 3. Compile for both architectures
    SDK_PATH=$(xcrun --show-sdk-path)
    
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

    # 4. Create Universal Binary
    log "Stitching Universal Binary (Lipo)..."
    lipo -create "$BUILD_DIR/PolarFlux_arm64" "$BUILD_DIR/PolarFlux_x86_64" -output "$MACOS_DIR/$APP_NAME"

    # 5. Bundle Resources
    log "Packaging resources..."
    if [ -f "Resources/Info.plist" ]; then
        cp Resources/Info.plist "$CONTENTS_DIR/"
    else
        error "Info.plist missing from Resources/"
    fi

    if [ -f "Resources/PolarFlux.icns" ]; then
        cp Resources/PolarFlux.icns "$RESOURCES_DIR/"
    else
        warn "Icon missing, app will have default icon."
    fi

    # Copy Localization Files (.lproj)
    log "Packaging localizations..."
    find Resources -name "*.lproj" -type d -exec cp -R {} "$RESOURCES_DIR/" \;

    # 6. Code Signing
    log "Applying Ad-hoc signature..."
    codesign --force --deep --sign - "$APP_BUNDLE"

    success "PolarFlux.app is ready (Universal Binary)."
}

dmg() {
    build
    log "Packaging into Modern DMG..."
    
    VERSION_STR="${VERSION:-$(date +%Y.%m.%d)}"
    DMG_NAME="${APP_NAME}_v${VERSION_STR}.dmg"
    DMG_PATH="$PROJECT_ROOT/$DMG_NAME"
    TEMP_DMG="$BUILD_DIR/temp.dmg"
    MOUNT_POINT="$BUILD_DIR/mnt"
    
    rm -f "$DMG_PATH" "$TEMP_DMG"
    mkdir -p "$MOUNT_POINT"
    
    # 1. Create a temporary writable DMG
    hdiutil create -size 200m -fs HFS+ -volname "$APP_NAME" "$TEMP_DMG"
    
    # 2. Mount it
    log "Mounting temporary disk..."
    hdiutil attach "$TEMP_DMG" -noautoopen -mountpoint "$MOUNT_POINT"
    
    # 3. Copy App and create Applications link
    cp -R "$APP_BUNDLE" "$MOUNT_POINT/"
    ln -s /Applications "$MOUNT_POINT/Applications"
    
    # 4. Style the DMG using AppleScript
    log "Applying modern styling..."
    osascript <<EOF
    tell application "Finder"
        tell disk "$APP_NAME"
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
            close
            open
            update without registering applications
            delay 2
        end tell
    end tell
EOF

    # 5. Finalize
    log "Finalizing DMG..."
    chmod -Rf go-w "$MOUNT_POINT" || true
    hdiutil detach "$MOUNT_POINT"
    hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
    
    rm -f "$TEMP_DMG"
    rm -rf "$MOUNT_POINT"
    success "Modern package created: $DMG_NAME"
}

run() {
    build
    log "Launching application..."
    open "$APP_BUNDLE"
}

# --- Main ---
case "${1:-build}" in
    build) build ;;
    run)   run ;;
    dmg)   dmg ;;
    clean) clean ;;
    icon)  generate_icon ;;
    help)  show_help ;;
    *)     error "Unknown command: $1. Use '$0 help' for usage." ;;
esac
