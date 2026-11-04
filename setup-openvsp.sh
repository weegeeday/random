#!/usr/bin/env bash
# ==============================================================================
# Bazzite OpenVSP + VSPAERO Distrobox Provisioner & Desktop Integrator
# ==============================================================================
set -Eeuo pipefail

CONTAINER_NAME="openvsp-box"
CONTAINER_IMAGE="ubuntu:24.04"
APPS_DIR="${HOME}/.local/share/applications"

# Terminal color output helpers
info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# 1. Host Sanity Checks
# ------------------------------------------------------------------------------
info "Checking host environment prerequisites..."

if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root/sudo. Run it as your normal desktop user."
fi

command -v distrobox >/dev/null 2>&1 || error "Distrobox is not installed or not in PATH."

if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    error "Neither Podman nor Docker runtime found."
fi

mkdir -p "${APPS_DIR}"

# ------------------------------------------------------------------------------
# 2. Container Initialization
# ------------------------------------------------------------------------------
if distrobox list | grep -qw "${CONTAINER_NAME}"; then
    info "Container '${CONTAINER_NAME}' already exists. Reusing existing container."
else
    info "Creating Distrobox container '${CONTAINER_NAME}' with image '${CONTAINER_IMAGE}'..."
    distrobox create --yes --image "${CONTAINER_IMAGE}" --name "${CONTAINER_NAME}" || error "Failed to create container."
    ok "Container created successfully."
fi

# ------------------------------------------------------------------------------
# 3. In-Container Package Installation & OpenVSP Setup
# ------------------------------------------------------------------------------
info "Provisioning OpenVSP inside '${CONTAINER_NAME}'..."

distrobox enter "${CONTAINER_NAME}" -- bash -c '
    set -Eeuo pipefail
    export DEBIAN_FRONTEND=noninteractive

    # Install runtime and graphics dependencies for OpenVSP & FLTK GUI
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        curl \
        wget \
        ca-certificates \
        libgl1 \
        libglx-mesa0 \
        libgl1-mesa-dri \
        libglu1-mesa \
        libglew2.2 \
        libfltk1.3t64 \
        libfltk-gl1.3t64 \
        libxml2 \
        libcminpack1 \
        freeglut3-dev \
        python3

    # Fetch latest Ubuntu 24.04 .deb download link from openvsp.org
    DEB_REL_PATH=$(curl -fsSL https://openvsp.org/download.php | grep -oE "zips/current/linux/OpenVSP-[0-9.]+-Ubuntu-24\.04_amd64\.deb" | head -n 1 || true)
    if [ -z "$DEB_REL_PATH" ]; then
        DEB_REL_PATH="zips/current/linux/OpenVSP-3.55.0-Ubuntu-24.04_amd64.deb"
    fi

    echo "Downloading https://openvsp.org/${DEB_REL_PATH}..."
    wget -qO /tmp/openvsp.deb "https://openvsp.org/download.php?file=${DEB_REL_PATH}"
    sudo apt-get install -y /tmp/openvsp.deb
    rm -f /tmp/openvsp.deb

    # Symlink binaries from /opt/OpenVSP* into /usr/local/bin if not already in PATH
    VSP_BIN=$(find /opt /usr -name "vsp" -type f -executable 2>/dev/null | head -n 1 || true)
    if [ -n "$VSP_BIN" ]; then
        VSP_DIR=$(dirname "$VSP_BIN")
        for bin in vsp vspaero vspscript vspviewer vsploads; do
            if [ -f "$VSP_DIR/$bin" ]; then
                sudo ln -sf "$VSP_DIR/$bin" "/usr/local/bin/$bin"
            fi
        done
    fi

    # Create container-side .desktop file so distrobox-export works cleanly
    sudo mkdir -p /usr/share/applications
    sudo tee /usr/share/applications/openvsp.desktop >/dev/null << "INNER_EOF"
[Desktop Entry]
Type=Application
Name=OpenVSP
GenericName=Aircraft Geometry Modeling
Comment=NASA Open Vehicle Sketch Pad Parametric Aircraft Geometry Tool
Exec=/usr/local/bin/vsp
Icon=applications-engineering
Terminal=false
Categories=Science;Engineering;
StartupNotify=true
INNER_EOF
' || error "Failed to install OpenVSP inside container."

ok "OpenVSP and VSPAERO installed and configured."

# ------------------------------------------------------------------------------
# 4. Desktop Menu Integration (GUI + CLI Launchers)
# ------------------------------------------------------------------------------
info "Integrating GUI launchers into Bazzite KDE desktop environment..."

# Export OpenVSP GUI app to host
distrobox enter "${CONTAINER_NAME}" -- distrobox-export --app openvsp || warn "distrobox-export failed, creating custom desktop file instead."

# Detect host terminal emulator for CLI workspace
TERM_EXEC="ptyxis --"
if ! command -v ptyxis >/dev/null 2>&1; then
    if command -v konsole >/dev/null 2>&1; then
        TERM_EXEC="konsole -e"
    else
        TERM_EXEC="xterm -e"
    fi
fi

# Ensure a dedicated OpenVSP CLI workspace shortcut (for VSPAERO / vspscript) exists
OPENVSP_CLI_DESKTOP="${APPS_DIR}/openvsp-workspace.desktop"

cat << EOF > "${OPENVSP_CLI_DESKTOP}"
[Desktop Entry]
Type=Application
Name=OpenVSP CLI Workspace
GenericName=VSPAERO & Scripting Terminal
Comment=Terminal environment for VSPAERO solver and vspscript automation
Exec=${TERM_EXEC} distrobox enter ${CONTAINER_NAME}
Icon=utilities-terminal
Terminal=false
Categories=Science;Engineering;
StartupNotify=true
EOF

chmod +x "${OPENVSP_CLI_DESKTOP}"

# Refresh desktop database and KDE sycoca cache
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
fi

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
fi

killall krunner >/dev/null 2>&1 || true

ok "Desktop integrations generated successfully."

# ------------------------------------------------------------------------------
# 5. Verification Test
# ------------------------------------------------------------------------------
info "Testing OpenVSP CLI & Solver binaries..."
if distrobox enter "${CONTAINER_NAME}" -- bash -c "command -v vsp && command -v vspaero" >/dev/null 2>&1; then
    ok "Verification passed! OpenVSP ('vsp') and solver ('vspaero') are ready."
else
    warn "Binary check returned a warning. Check 'distrobox enter ${CONTAINER_NAME}' manually."
fi

echo ""
echo "=========================================================================="
echo " Setup complete! You can now access:"
echo " 1. 'OpenVSP' (3D Parametric Aircraft GUI) from the Application Launcher"
echo " 2. 'OpenVSP CLI Workspace' (VSPAERO / Scripting) from the Launcher"
echo "=========================================================================="