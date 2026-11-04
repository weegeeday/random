#!/usr/bin/env bash
# ==============================================================================
# Bazzite OpenVSP + VSPAERO Distrobox Provisioner & Desktop 
# ==============================================================================
set -Eeuo pipefail

main() {
    CONTAINER_NAME="openvsp-box"
    CONTAINER_IMAGE="ubuntu:24.04"
    APPS_DIR="${HOME}/.local/share/applications"

    # Terminal color output helpers
    info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
    ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
    warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
    error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

    # --------------------------------------------------------------------------
    # 1. Host Sanity Checks
    # --------------------------------------------------------------------------
    info "Checking host environment prerequisites..."

    if [[ $EUID -eq 0 ]]; then
        error "Do not run this script as root/sudo. Run it as your normal desktop user."
    fi

    command -v distrobox >/dev/null 2>&1 || error "Distrobox is not installed or not in PATH."

    if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        error "Neither Podman nor Docker runtime found."
    fi

    mkdir -p "${APPS_DIR}"

    # --------------------------------------------------------------------------
    # 2. Container Initialization
    # --------------------------------------------------------------------------
    if distrobox list | grep -qw "${CONTAINER_NAME}"; then
        info "Container '${CONTAINER_NAME}' already exists. Reusing existing container."
    else
        info "Creating Distrobox container '${CONTAINER_NAME}' with image '${CONTAINER_IMAGE}'..."
        distrobox create --yes --image "${CONTAINER_IMAGE}" --name "${CONTAINER_NAME}" </dev/null || error "Failed to create container."
        ok "Container created successfully."
    fi

    # --------------------------------------------------------------------------
    # 3. In-Container Package Installation & OpenVSP Setup
    # --------------------------------------------------------------------------
    info "Provisioning OpenVSP inside '${CONTAINER_NAME}'..."

    distrobox enter "${CONTAINER_NAME}" -- bash -c '
        export DEBIAN_FRONTEND=noninteractive

        sudo dpkg --remove --force-remove-reinstreq openvsp >/dev/null 2>&1 || true

        sudo apt-get update -y
        sudo apt-get install -y --no-install-recommends \
            curl \
            wget \
            ca-certificates \
            desktop-file-utils \
            xdg-utils \
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

        DEB_REL_PATH=$(curl -fsSL https://openvsp.org/download.php | grep -oE "zips/current/linux/OpenVSP-[0-9.]+-Ubuntu-24\.04_amd64\.deb" | head -n 1 || true)
        if [ -z "$DEB_REL_PATH" ]; then
            DEB_REL_PATH="zips/current/linux/OpenVSP-3.55.0-Ubuntu-24.04_amd64.deb"
        fi

        echo "Downloading https://openvsp.org/${DEB_REL_PATH}..."
        wget -qO /tmp/openvsp.deb "https://openvsp.org/download.php?file=${DEB_REL_PATH}"
        sudo apt-get install -y /tmp/openvsp.deb
        rm -f /tmp/openvsp.deb

        for dir in /opt/OpenVSP* /usr/local/bin /usr/bin; do
            if [ -f "$dir/vsp" ]; then
                for bin in vsp vspaero vspscript vspviewer vsploads; do
                    [ -f "$dir/$bin" ] && sudo ln -sf "$dir/$bin" "/usr/local/bin/$bin" || true
                done
                break
            fi
        done
    ' </dev/null || error "Failed to install OpenVSP inside container."

    ok "OpenVSP and VSPAERO installed and configured."

    # --------------------------------------------------------------------------
    # 4. Desktop Menu Integration
    # --------------------------------------------------------------------------
    info "Generating KDE Plasma desktop launchers on host..."

    OPENVSP_GUI_DESKTOP="${APPS_DIR}/openvsp-gui.desktop"
    cat > "${OPENVSP_GUI_DESKTOP}" << EOF
[Desktop Entry]
Type=Application
Name=OpenVSP
GenericName=Aircraft Geometry Modeling
Comment=NASA Open Vehicle Sketch Pad Parametric Aircraft Geometry Tool
Exec=distrobox-enter --name ${CONTAINER_NAME} -- vsp
Icon=applications-engineering
Terminal=false
Categories=Science;Engineering;
StartupNotify=true
EOF

    OPENVSP_CLI_DESKTOP="${APPS_DIR}/openvsp-workspace.desktop"
    if command -v ptyxis >/dev/null 2>&1; then
        TERMINAL_COMMAND="ptyxis -- distrobox-enter --name ${CONTAINER_NAME} -- bash -l"
    elif command -v konsole >/dev/null 2>&1; then
        TERMINAL_COMMAND="konsole -e distrobox-enter --name ${CONTAINER_NAME} -- bash -l"
    elif command -v xterm >/dev/null 2>&1; then
        TERMINAL_COMMAND="xterm -e distrobox-enter --name ${CONTAINER_NAME} -- bash -l"
    else
        error "No supported terminal emulator found (ptyxis, konsole, or xterm)."
    fi

    cat > "${OPENVSP_CLI_DESKTOP}" << EOF
[Desktop Entry]
Type=Application
Name=OpenVSP CLI Workspace
GenericName=VSPAERO & Scripting Terminal
Comment=Terminal environment for VSPAERO solver and vspscript automation
Exec=${TERMINAL_COMMAND}
Icon=utilities-terminal
Terminal=false
Categories=Science;Engineering;
StartupNotify=true
EOF

    chmod 644 "${OPENVSP_GUI_DESKTOP}" "${OPENVSP_CLI_DESKTOP}"
    update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
    kbuildsycoca6 --noincremental >/dev/null 2>&1 || kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
    killall krunner >/dev/null 2>&1 || true

    ok "Desktop launchers created and indexed."

    echo ""
    echo "=========================================================================="
    echo " Setup complete! You can now access:"
    echo " 1. 'OpenVSP' (3D Parametric Aircraft GUI) from the Application Launcher"
    echo " 2. 'OpenVSP CLI Workspace' (VSPAERO / Scripting) from the Launcher"
    echo "=========================================================================="
}

main "$@"
