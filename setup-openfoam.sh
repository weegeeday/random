#!/usr/bin/env bash
# ==============================================================================
# Bazzite OpenFOAM + ParaView Distrobox Provisioner & Desktop Integrator
# ==============================================================================
set -Eeuo pipefail

CONTAINER_NAME="openfoam-box"
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
# 3. In-Container Package Installation & Environment Setup
# ------------------------------------------------------------------------------
info "Provisioning OpenFOAM and ParaView packages inside '${CONTAINER_NAME}'..."
info "This may take a few minutes depending on your internet connection."

distrobox enter "${CONTAINER_NAME}" -- bash -c '
    set -Eeuo pipefail

    export DEBIAN_FRONTEND=noninteractive

    # Speed up package installations by avoiding man-db cache generation in container
    if [ -d /etc/dpkg/dpkg.cfg.d ]; then
        echo "path-exclude=/usr/share/man/*" | sudo tee /etc/dpkg/dpkg.cfg.d/01_nodoc >/dev/null || true
    fi

    # Install repository dependencies and graphics libraries
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        software-properties-common \
        libgl1 \
        libglx-mesa0 \
        libgl1-mesa-dri

    # Ensure universe repository is enabled (required for ParaView and CGAL dependencies)
    sudo add-apt-repository -y universe || true

    # Add official OpenFOAM Debian/Ubuntu repository
    if [ ! -f /etc/apt/sources.list.d/openfoam.list ]; then
        curl -s https://dl.openfoam.com/add-debian-repo.sh | sudo bash
    fi

    # Update repositories and install OpenFOAM + system ParaView
    sudo apt-get update -y
    sudo apt-get install -y openfoam-default paraview || {
        # Fallback to latest versioned package if openfoam-default meta-package has conflicts
        LATEST_PKG=$(apt-cache search "^openfoam[0-9]+-default" | sort -V | tail -n1 | awk "{print \$1}")
        if [ -n "$LATEST_PKG" ]; then
            sudo apt-get install -y "$LATEST_PKG" paraview
        else
            exit 1
        fi
    }

    # Find the installed OpenFOAM bashrc inside the container
    BASHRC_TARGET=$(ls -d /usr/lib/openfoam/openfoam*/etc/bashrc 2>/dev/null | head -n 1 || true)

    # Configure auto-sourcing strictly INSIDE the container (/etc/profile.d and /etc/bash.bashrc)
    # NOTE: We DO NOT write to $HOME/.bashrc because Distrobox shares the host $HOME directory!
    if [ -n "$BASHRC_TARGET" ]; then
        echo "source $BASHRC_TARGET" | sudo tee /etc/profile.d/openfoam.sh >/dev/null
        if ! grep -Fq "$BASHRC_TARGET" /etc/bash.bashrc 2>/dev/null; then
            echo "[ -f $BASHRC_TARGET ] && source $BASHRC_TARGET" | sudo tee -a /etc/bash.bashrc >/dev/null
        fi
    fi
' || error "Failed to install OpenFOAM packages inside container."

ok "OpenFOAM and ParaView installed and configured."

# Clean up any accidental host ~/.bashrc contamination from prior runs
if grep -q "openfoam.*etc/bashrc" "${HOME}/.bashrc" 2>/dev/null; then
    info "Removing container-only OpenFOAM bashrc line from host ~/.bashrc..."
    sed -i '/openfoam.*etc\/bashrc/d' "${HOME}/.bashrc" || true
fi

# ------------------------------------------------------------------------------
# 4. Desktop Menu Integration (Non-Terminal User Access)
# ------------------------------------------------------------------------------
info "Integrating GUI launchers into Bazzite desktop environment..."

# 1. Export ParaView desktop entry from container to host
PARAVIEW_EXPORTED=false
if distrobox enter "${CONTAINER_NAME}" -- distrobox-export --app paraview 2>/dev/null; then
    PARAVIEW_EXPORTED=true
    ok "ParaView exported via distrobox-export."
fi

# 2. If distrobox-export failed or didn't create a desktop file, provide a dedicated launcher
PARAVIEW_DESKTOP="${APPS_DIR}/${CONTAINER_NAME}-paraview.desktop"
if [ "$PARAVIEW_EXPORTED" = false ] || [ ! -f "${PARAVIEW_DESKTOP}" ]; then
    warn "Creating custom ParaView desktop launcher (${PARAVIEW_DESKTOP})..."

    # Try to extract the ParaView SVG icon from the container to host icon directory
    mkdir -p "${HOME}/.local/share/icons/hicolor/scalable/apps"
    distrobox enter "${CONTAINER_NAME}" -- cat /usr/share/icons/hicolor/scalable/apps/paraview.svg \
        > "${HOME}/.local/share/icons/hicolor/scalable/apps/${CONTAINER_NAME}-paraview.svg" 2>/dev/null || true

    cat << EOF > "${PARAVIEW_DESKTOP}"
[Desktop Entry]
Type=Application
Name=ParaView (${CONTAINER_NAME})
GenericName=3D Data Visualizer
Comment=Parallel Visualization Application (via ${CONTAINER_NAME})
Exec=distrobox enter ${CONTAINER_NAME} -- paraview %U
Icon=${CONTAINER_NAME}-paraview
Terminal=false
Categories=Science;Engineering;DataVisualization;Graphics;
StartupNotify=true
MimeType=application/x-paraview;
EOF
    chmod +x "${PARAVIEW_DESKTOP}"
    ok "Custom ParaView launcher created."
fi

# 3. Ensure a dedicated OpenFOAM workspace shortcut exists
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
Categories=Science;Engineering;Education;
StartupNotify=true
EOF

chmod +x "${OPENFOAM_DESKTOP_FILE}"

# Refresh KDE / desktop application database caches
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
fi

# Refresh KDE Plasma menu cache specifically
if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    kbuildsycoca5 >/dev/null 2>&1 || true
fi

ok "Desktop integrations generated successfully."

# ------------------------------------------------------------------------------
# 5. Verification Test
# ------------------------------------------------------------------------------
info "Testing OpenFOAM environment execution..."
if distrobox enter "${CONTAINER_NAME}" -- bash -ic "foamVersion" >/dev/null 2>&1; then
    ok "Verification passed! OpenFOAM is functioning correctly."
else
    warn "Automated test returned an exit code warning. Check 'distrobox enter ${CONTAINER_NAME}' manually."
fi

echo ""
echo "=========================================================================="
echo " Setup complete! The user can now access:"
echo " 1. ParaView (3D visualizer) from the Application Launcher"
echo " 2. 'OpenFOAM Workspace' from the Application Launcher"
echo "=========================================================================="
