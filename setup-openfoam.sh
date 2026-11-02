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

    # Install repository dependencies and graphics libraries
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        software-properties-common \
        libgl1-mesa-glx \
        libgl1-mesa-dri

    # Add official OpenFOAM Debian/Ubuntu repository
    if [ ! -f /etc/apt/sources.list.d/openfoam.list ]; then
        curl -s https://dl.openfoam.com/add-debian-repo.sh | sudo bash
    fi

    # Update repositories and install OpenFOAM + system ParaView
    sudo apt-get update -y
    sudo apt-get install -y openfoam-default paraview

    # Auto-source OpenFOAM environment in the container bash shell
    if ! grep -q "openfoam/etc/bashrc" "$HOME/.bashrc" 2>/dev/null; then
        echo "source /usr/lib/openfoam/openfoam/etc/bashrc" >> "$HOME/.bashrc"
    fi
' || error "Failed to install OpenFOAM packages inside container."

ok "OpenFOAM and ParaView installed and configured."

# ------------------------------------------------------------------------------
# 4. Desktop Menu Integration (Non-Terminal User Access)
# ------------------------------------------------------------------------------
info "Integrating GUI launchers into Bazzite desktop environment..."

# Export native ParaView desktop entry from container to host
distrobox enter "${CONTAINER_NAME}" -- distrobox-export --app paraview || warn "distrobox-export failed, creating custom desktop file instead."

# Ensure a dedicated OpenFOAM workspace shortcut exists
OPENFOAM_DESKTOP_FILE="${APPS_DIR}/openfoam-workspace.desktop"

cat << 'EOF' > "${OPENFOAM_DESKTOP_FILE}"
[Desktop Entry]
Type=Application
Name=OpenFOAM Workspace
GenericName=CFD Environment
Comment=Pre-configured OpenFOAM computational fluid dynamics workspace
Exec=distrobox enter openfoam-box
Icon=utilities-terminal
Terminal=true
Categories=Science;Engineering;Education;
StartupNotify=true
EOF

chmod +x "${OPENFOAM_DESKTOP_FILE}"

# Refresh application database caches
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
fi

ok "Desktop integrations generated successfully."

# ------------------------------------------------------------------------------
# 5. Verification Test
# ------------------------------------------------------------------------------
info "Testing OpenFOAM environment execution..."
if distrobox enter "${CONTAINER_NAME}" -- bash -c "source /usr/lib/openfoam/openfoam/etc/bashrc && foamVersion" >/dev/null 2>&1; then
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