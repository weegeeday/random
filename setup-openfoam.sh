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
mkdir -p "${HOME}/OpenFOAM"

# ------------------------------------------------------------------------------
# 2. Desktop Integration on Host (Created IMMEDIATELY on the host)
# ------------------------------------------------------------------------------
info "Registering desktop shortcuts in Bazzite application menu..."

# 1. ParaView GUI launcher
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
Keywords=para;paraview;foam;cfd;visualization;3d;
StartupNotify=true
MimeType=application/x-paraview;
EOF
chmod +x "${PARAVIEW_DESKTOP}"

# 2. OpenFOAM Workspace launcher
OPENFOAM_DESKTOP_FILE="${APPS_DIR}/openfoam-workspace.desktop"
cat << EOF > "${OPENFOAM_DESKTOP_FILE}"
[Desktop Entry]
Type=Application
Name=OpenFOAM Workspace
GenericName=CFD Environment
Comment=Pre-configured OpenFOAM computational fluid dynamics workspace
Exec=distrobox enter ${CONTAINER_NAME} -- /usr/local/bin/openfoam-workspace
Icon=utilities-terminal
Terminal=true
Categories=Science;Engineering;Development;Education;
Keywords=foam;openfoam;cfd;solver;simulation;workspace;
Path=${HOME}/OpenFOAM
StartupNotify=true
EOF
chmod +x "${OPENFOAM_DESKTOP_FILE}"

# Refresh application databases immediately so shortcuts are indexed right away
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
fi

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 >/dev/null 2>&1 || true
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
    kbuildsycoca5 >/dev/null 2>&1 || true
fi

ok "Desktop shortcuts registered on host successfully."

# ------------------------------------------------------------------------------
# 3. Container Initialization
# ------------------------------------------------------------------------------
if distrobox list < /dev/null | grep -qw "${CONTAINER_NAME}"; then
    info "Container '${CONTAINER_NAME}' already exists. Reusing existing container."
else
    info "Creating Distrobox container '${CONTAINER_NAME}' with image '${CONTAINER_IMAGE}'..."
    distrobox create --yes --image "${CONTAINER_IMAGE}" --name "${CONTAINER_NAME}" < /dev/null || error "Failed to create container."
    ok "Container created successfully."
fi

# ------------------------------------------------------------------------------
# 4. In-Container Package Installation & Environment Setup
# ------------------------------------------------------------------------------
info "Automating package installation inside '${CONTAINER_NAME}'..."
info "Downloading and configuring OpenFOAM + ParaView. Please wait..."

# CRITICAL: Always redirect stdin from /dev/null (< /dev/null) so distrobox enter does not consume the curl stream!
distrobox enter -T --name "${CONTAINER_NAME}" -- bash -c '
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
    if ! sudo apt-get install -y openfoam-default paraview 2>/dev/null; then
        if ! sudo apt-get install -y openfoam2412-default paraview 2>/dev/null; then
            sudo apt-get install -y openfoam2406-default paraview
        fi
    fi

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
' < /dev/null || error "Failed to install OpenFOAM packages inside container."

# Install dedicated OpenFOAM workspace session launcher inside container
cat << 'EOS' | distrobox enter -T --name "${CONTAINER_NAME}" -- sudo tee /usr/local/bin/openfoam-workspace >/dev/null
#!/usr/bin/env bash
BASHRC_TARGET=$(ls -d /usr/lib/openfoam/openfoam*/etc/bashrc 2>/dev/null | head -n 1 || true)
if [ -n "$BASHRC_TARGET" ] && [ -f "$BASHRC_TARGET" ]; then
    source "$BASHRC_TARGET"
fi

WORKSPACE="${HOME}/OpenFOAM"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo -e "\033[1;34m========================================================================\033[0m"
echo -e "\033[1;32m  OpenFOAM Computational Fluid Dynamics (CFD) Workspace\033[0m"
echo -e "\033[1;34m========================================================================\033[0m"
echo -e "  \033[1mWorking Directory:\033[0m  \033[36m$PWD\033[0m"
if [ -n "${WM_PROJECT_VERSION:-}" ]; then
    echo -e "  \033[1mOpenFOAM Version:\033[0m   OpenFOAM-$WM_PROJECT_VERSION"
fi
echo -e "  \033[1mSolvers:\033[0m            simpleFoam, pimpleFoam, interFoam, icoFoam"
echo -e "  \033[1mMeshing:\033[0m            blockMesh, snappyHexMesh"
echo -e "  \033[1mVisualization:\033[0m      paraFoam, paraview"
if [ -n "${FOAM_TUTORIALS:-}" ]; then
    echo -e "  \033[1mTutorials:\033[0m          \$FOAM_TUTORIALS"
fi
echo -e "\033[1;34m========================================================================\033[0m"
echo -e "  Tip: Copy a tutorial to get started:"
echo -e "       \033[33mcp -r \$FOAM_TUTORIALS/incompressible/simpleFoam/pitzDaily .\033[0m"
echo -e "\033[1;34m========================================================================\033[0m\n"

exec bash --login -i
EOS
distrobox enter -T --name "${CONTAINER_NAME}" -- sudo chmod +x /usr/local/bin/openfoam-workspace < /dev/null

ok "OpenFOAM and ParaView installed and configured inside container."

# Clean up any accidental host ~/.bashrc contamination from prior runs
if grep -q "openfoam.*etc/bashrc" "${HOME}/.bashrc" 2>/dev/null; then
    info "Removing container-only OpenFOAM bashrc line from host ~/.bashrc..."
    sed -i '/openfoam.*etc\/bashrc/d' "${HOME}/.bashrc" || true
fi

# ------------------------------------------------------------------------------
# 5. Icon Extraction & Cache Refresh
# ------------------------------------------------------------------------------
info "Caching application icons..."

for size in 16x16 22x22 32x32 48x48 64x64 96x96 128x128 256x256; do
    mkdir -p "${ICONS_DIR}/${size}/apps"
    distrobox enter -T --name "${CONTAINER_NAME}" -- sh -c "
        if [ -f /usr/share/icons/hicolor/${size}/apps/paraview.png ]; then
            cat /usr/share/icons/hicolor/${size}/apps/paraview.png
        elif [ -f /usr/share/pixmaps/paraview.png ]; then
            cat /usr/share/pixmaps/paraview.png
        fi
    " < /dev/null > "${ICONS_DIR}/${size}/apps/paraview.png" 2>/dev/null || true
    [ -s "${ICONS_DIR}/${size}/apps/paraview.png" ] || rm -f "${ICONS_DIR}/${size}/apps/paraview.png"
done

# Try distrobox-export in background as supplementary
distrobox enter -T --name "${CONTAINER_NAME}" -- distrobox-export --app paraview < /dev/null >/dev/null 2>&1 || true

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
# 6. Verification Test & Non-Terminal Feedback
# ------------------------------------------------------------------------------
info "Testing OpenFOAM environment execution..."
if distrobox enter -T --name "${CONTAINER_NAME}" -- bash -ic "foamVersion" < /dev/null >/dev/null 2>&1; then
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
