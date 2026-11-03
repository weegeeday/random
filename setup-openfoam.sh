#!/usr/bin/env bash
# ==============================================================================
# Bazzite OpenFOAM + ParaView Distrobox Automated Installer
# Designed for 100% hands-off automation and non-terminal users
# ==============================================================================
set -Eeuo pipefail

CONTAINER_NAME="openfoam-box"
CONTAINER_IMAGE="ubuntu:24.04"
APPS_DIR="${HOME}/.local/share/applications"
ICONS_DIR="${HOME}/.local/share/icons/hicolor"

# Terminal color output helpers
info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { 
    echo -e "\e[31m[ERROR]\e[0m $*" >&2
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical -a "OpenFOAM Installer" "Installation Error" "$*" 2>/dev/null || true
    fi
    exit 1
}

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
mkdir -p "${ICONS_DIR}/scalable/apps"
mkdir -p "${ICONS_DIR}/48x48/apps"

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
# 3. In-Container Package Installation & Environment Setup
# ------------------------------------------------------------------------------
info "Automating package installation inside '${CONTAINER_NAME}'..."
info "Downloading and configuring OpenFOAM + ParaView. Please wait..."

distrobox enter --no-tty "${CONTAINER_NAME}" -- bash -c '
    set -Eeuo pipefail

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export APT_LISTCHANGES_FRONTEND=none

    # Prevent man-db cache building and documentation from slowing down container creation
    if [ -d /etc/dpkg/dpkg.cfg.d ]; then
        echo "path-exclude=/usr/share/man/*" | sudo tee /etc/dpkg/dpkg.cfg.d/01_nodoc >/dev/null || true
    fi
    echo "man-db man-db/auto-update boolean false" | sudo debconf-set-selections 2>/dev/null || true

    # Install foundational tools, GPG, and Mesa OpenGL graphics runtime
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        software-properties-common \
        libgl1 \
        libglx-mesa0 \
        libgl1-mesa-dri

    # Ensure Ubuntu universe repository is enabled (required for ParaView and dependencies)
    sudo add-apt-repository -y universe || true

    # Add official OpenFOAM Debian/Ubuntu repository
    if [ ! -f /etc/apt/sources.list.d/openfoam.list ]; then
        curl -s https://dl.openfoam.com/add-debian-repo.sh | sudo bash
    fi

    # Update package lists and install OpenFOAM and ParaView
    sudo apt-get update -y
    sudo apt-get install -y openfoam-default paraview || {
        # Fallback to latest explicit package version if openfoam-default meta-package has conflicts
        LATEST_PKG=$(apt-cache search "^openfoam[0-9]+-default" | sort -V | tail -n1 | awk "{print \$1}")
        if [ -n "$LATEST_PKG" ]; then
            sudo apt-get install -y "$LATEST_PKG" paraview
        else
            exit 1
        fi
    }

    # Locate installed OpenFOAM bashrc
    BASHRC_TARGET=$(ls -d /usr/lib/openfoam/openfoam*/etc/bashrc 2>/dev/null | head -n 1 || true)

    # Configure auto-sourcing strictly INSIDE container (/etc/profile.d and /etc/bash.bashrc)
    # Never write to $HOME/.bashrc because Distrobox shares the host $HOME directory!
    if [ -n "$BASHRC_TARGET" ]; then
        echo "[ -f \"$BASHRC_TARGET\" ] && source \"$BASHRC_TARGET\"" | sudo tee /etc/profile.d/openfoam.sh >/dev/null
        sudo chmod +x /etc/profile.d/openfoam.sh

        if ! grep -Fq "/etc/profile.d/openfoam.sh" /etc/bash.bashrc 2>/dev/null; then
            echo "[ -f /etc/profile.d/openfoam.sh ] && source /etc/profile.d/openfoam.sh" | sudo tee -a /etc/bash.bashrc >/dev/null
        fi
    fi
' || error "Failed to install OpenFOAM packages inside container."

ok "OpenFOAM and ParaView installed and configured inside container."

# Clean up any accidental host ~/.bashrc contamination from prior runs
if grep -q "openfoam.*etc/bashrc" "${HOME}/.bashrc" 2>/dev/null; then
    info "Removing container-only OpenFOAM bashrc line from host ~/.bashrc..."
    sed -i '/openfoam.*etc\/bashrc/d' "${HOME}/.bashrc" || true
fi

# ------------------------------------------------------------------------------
# 4. Desktop Menu Integration (Non-Terminal User Access)
# ------------------------------------------------------------------------------
info "Integrating GUI launchers into Bazzite desktop environment..."

# Extract ParaView icon from container to host icon cache for guaranteed icon display
distrobox enter --no-tty "${CONTAINER_NAME}" -- cat /usr/share/icons/hicolor/scalable/apps/paraview.svg \
    > "${ICONS_DIR}/scalable/apps/paraview.svg" 2>/dev/null || true
distrobox enter --no-tty "${CONTAINER_NAME}" -- cat /usr/share/icons/hicolor/scalable/apps/paraview.svg \
    > "${ICONS_DIR}/scalable/apps/${CONTAINER_NAME}-paraview.svg" 2>/dev/null || true

# Try distrobox-export first
PARAVIEW_EXPORTED=false
if distrobox enter --no-tty "${CONTAINER_NAME}" -- distrobox-export --app paraview 2>/dev/null; then
    PARAVIEW_EXPORTED=true
    ok "ParaView exported via distrobox-export."
fi

# Ensure ParaView launcher exists and has reliable Wayland/X11 flags
PARAVIEW_DESKTOP="${APPS_DIR}/${CONTAINER_NAME}-paraview.desktop"
cat << EOF > "${PARAVIEW_DESKTOP}"
[Desktop Entry]
Type=Application
Name=ParaView (${CONTAINER_NAME})
GenericName=3D Data Visualizer
Comment=Parallel Visualization Application (via ${CONTAINER_NAME})
Exec=distrobox enter ${CONTAINER_NAME} -- env QT_QPA_PLATFORM=xcb paraview %U
Icon=paraview
Terminal=false
Categories=Science;Engineering;DataVisualization;Graphics;
StartupNotify=true
MimeType=application/x-paraview;
EOF
chmod +x "${PARAVIEW_DESKTOP}"
ok "ParaView desktop launcher configured."

# Ensure dedicated OpenFOAM workspace shortcut exists
OPENFOAM_DESKTOP_FILE="${APPS_DIR}/openfoam-workspace.desktop"
cat << EOF > "${OPENFOAM_DESKTOP_FILE}"
[Desktop Entry]
Type=Application
Name=OpenFOAM Workspace
GenericName=CFD Environment
Comment=Pre-configured OpenFOAM computational fluid dynamics workspace
Exec=distrobox enter ${CONTAINER_NAME}
Icon=utilities-terminal
Terminal=true
Categories=Science;Engineering;Development;Education;
StartupNotify=true
EOF
chmod +x "${OPENFOAM_DESKTOP_FILE}"
ok "OpenFOAM Workspace launcher configured."

# Refresh desktop database and KDE Plasma application menu caches
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
fi

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    kbuildsycoca5 >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------------------
# 5. Verification Test & Non-Terminal Feedback
# ------------------------------------------------------------------------------
info "Testing OpenFOAM environment execution..."
if distrobox enter --no-tty "${CONTAINER_NAME}" -- bash -ic "foamVersion" >/dev/null 2>&1; then
    ok "Verification passed! OpenFOAM is functioning correctly."
else
    warn "Automated test returned an exit code warning. Check container manually."
fi

# Trigger native desktop notification for non-terminal user feedback
if command -v notify-send >/dev/null 2>&1; then
    notify-send -a "OpenFOAM Installer" -i "system-software-install" \
        "OpenFOAM & ParaView Ready" \
        "Installation complete! 'OpenFOAM Workspace' and 'ParaView' are now in your Application Launcher." 2>/dev/null || true
elif command -v kdialog >/dev/null 2>&1; then
    kdialog --passivepopup "OpenFOAM & ParaView installation complete! Launch them from your Application Launcher." 10 2>/dev/null || true
fi

echo ""
echo "=========================================================================="
echo " Setup complete! The user can now access:"
echo " 1. ParaView (3D visualizer) from the Application Launcher"
echo " 2. 'OpenFOAM Workspace' from the Application Launcher"
echo "=========================================================================="
