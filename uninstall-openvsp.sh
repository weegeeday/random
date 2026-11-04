#!/usr/bin/env bash
# ==============================================================================
# Bazzite OpenVSP Distrobox Uninstaller & Desktop Cleanup
# ==============================================================================
set -Eeuo pipefail

CONTAINER_NAME="openvsp-box"
APPS_DIR="${HOME}/.local/share/applications"

info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
    error "Do not run this script as root/sudo. Run it as your normal desktop user."
fi

if distrobox list | grep -qw "${CONTAINER_NAME}"; then
    info "Unexporting OpenVSP from host desktop..."
    distrobox enter "${CONTAINER_NAME}" -- distrobox-export --app openvsp --delete >/dev/null 2>&1 || true

    info "Stopping and removing Distrobox container '${CONTAINER_NAME}'..."
    distrobox stop --yes "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    distrobox rm --yes --force "${CONTAINER_NAME}" || error "Failed to remove container."
    ok "Container '${CONTAINER_NAME}' removed."
else
    warn "Container '${CONTAINER_NAME}' does not exist. Skipping container removal."
fi

info "Cleaning up desktop shortcuts and refreshing KDE cache..."
rm -f \
    "${APPS_DIR}/openvsp-gui.desktop" \
    "${APPS_DIR}/openvsp-workspace.desktop"
find "${APPS_DIR}" -maxdepth 1 -type f \
    -name "${CONTAINER_NAME}-*.desktop" -delete

update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
kbuildsycoca6 --noincremental >/dev/null 2>&1 || kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
killall krunner >/dev/null 2>&1 || true

ok "Uninstallation complete!"
