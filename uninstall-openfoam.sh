#!/usr/bin/env bash
# ==============================================================================
# Bazzite OpenFOAM + ParaView Distrobox Uninstaller & Desktop Cleanup
# ==============================================================================
set -Eeuo pipefail

CONTAINER_NAME="openfoam-box"
APPS_DIR="${HOME}/.local/share/applications"

# Terminal color output helpers
info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# 1. Host Sanity Checks
# ------------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root/sudo. Run it as your normal desktop user."
fi

command -v distrobox >/dev/null 2>&1 || error "Distrobox is not installed or not in PATH."

# ------------------------------------------------------------------------------
# 2. Unexport & Stop / Remove Container
# ------------------------------------------------------------------------------
if distrobox list | grep -qw "${CONTAINER_NAME}"; then
    info "Unexporting ParaView from host desktop..."
    distrobox enter "${CONTAINER_NAME}" -- distrobox-export --app paraview --delete >/dev/null 2>&1 || true

    info "Stopping Distrobox container '${CONTAINER_NAME}'..."
    distrobox stop --yes "${CONTAINER_NAME}" >/dev/null 2>&1 || true

    info "Removing Distrobox container '${CONTAINER_NAME}'..."
    distrobox rm --yes --force "${CONTAINER_NAME}" || error "Failed to remove container."
    ok "Container '${CONTAINER_NAME}' removed successfully."
else
    warn "Container '${CONTAINER_NAME}' does not exist. Skipping container removal."
fi

# ------------------------------------------------------------------------------
# 3. Clean Up Desktop Launchers & Icons
# ------------------------------------------------------------------------------
info "Removing desktop entries and exported shortcuts..."

# Remove custom workspace desktop file
rm -f "${APPS_DIR}/openfoam-workspace.desktop"

# Clean any distrobox-exported desktop files and icons for openfoam-box
rm -f "${APPS_DIR}/${CONTAINER_NAME}"-*.desktop
rm -f "${HOME}/.local/share/icons/hicolor/"*/*/"${CONTAINER_NAME}"-* 2>/dev/null || true

# Refresh desktop application database
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
fi

ok "Desktop integrations cleaned up."

# ------------------------------------------------------------------------------
# 4. Verification
# ------------------------------------------------------------------------------
echo ""
echo "=========================================================================="
if ! distrobox list | grep -qw "${CONTAINER_NAME}"; then
    ok "Uninstallation complete! '${CONTAINER_NAME}' and all shortcuts removed."
else
    warn "Container '${CONTAINER_NAME}' may still be listed. Run 'distrobox list' to verify."
fi
echo "=========================================================================="