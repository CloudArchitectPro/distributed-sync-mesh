#!/usr/bin/env bash
# install-syncthing-pi.sh
#
# Idempotent Syncthing setup for a Raspberry Pi relay node (Debian 13).
# Safe to re-run on an already-configured system — existing config is preserved.
#
# What this script does:
#   1. Adds the Syncthing CANDIDATE apt channel (required for v2.x)
#   2. Installs or upgrades Syncthing
#   3. Enables and starts the systemd service under the current user
#   4. Patches config.xml to set connectionLimitMax and connectionLimitEnough to 0
#   5. Writes .stignore to the sync folder (if SYNC_FOLDER is set)
#   6. Prints post-install checklist
#
# Usage:
#   chmod +x install-syncthing-pi.sh
#   ./install-syncthing-pi.sh
#
# Optional: set SYNC_FOLDER before running to auto-place .stignore
#   SYNC_FOLDER=/home/pi/sync ./install-syncthing-pi.sh
#
# Requirements: Debian 13, sudo access, internet connection via Tailscale or WAN

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
CURRENT_USER="${USER}"
SYNCTHING_CONFIG_DIR="${HOME}/.local/state/syncthing"
SYNCTHING_CONFIG="${SYNCTHING_CONFIG_DIR}/config.xml"
KEYRING_PATH="/usr/share/keyrings/syncthing-archive-keyring.gpg"
APT_SOURCE="/etc/apt/sources.list.d/syncthing.list"

# ── Preflight checks ─────────────────────────────────────────────────────────
info "Running as user: ${CURRENT_USER}"
[[ "${CURRENT_USER}" == "root" ]] && error "Do not run as root. Run as your normal user with sudo available."
command -v sudo >/dev/null 2>&1 || error "sudo is required but not found."
command -v curl >/dev/null 2>&1 || { info "Installing curl..."; sudo apt-get install -y curl; }
command -v python3 >/dev/null 2>&1 || error "python3 is required for XML patching."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Distributed Sync Mesh — Pi Relay Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Add Syncthing CANDIDATE apt channel ───────────────────────────────
info "Step 1/6 — Configuring Syncthing apt repository (candidate channel)..."

if [[ -f "${APT_SOURCE}" ]] && grep -q "candidate" "${APT_SOURCE}"; then
    success "Candidate channel already configured — skipping."
else
    info "Adding Syncthing GPG key..."
    sudo mkdir -p /usr/share/keyrings
    curl -fsSL https://syncthing.net/release-key.gpg \
        | sudo gpg --dearmor -o "${KEYRING_PATH}"

    info "Writing apt source (candidate channel)..."
    echo "deb [signed-by=${KEYRING_PATH}] https://apt.syncthing.net/ syncthing candidate" \
        | sudo tee "${APT_SOURCE}" > /dev/null

    success "Candidate channel configured."
fi

# ── Step 2: Install / upgrade Syncthing ──────────────────────────────────────
info "Step 2/6 — Installing / upgrading Syncthing..."
sudo apt-get update -qq
sudo apt-get install -y syncthing

INSTALLED_VERSION=$(syncthing --version | awk '{print $2}')
info "Installed version: ${INSTALLED_VERSION}"

# Warn if somehow still on v1.x (should not happen after candidate channel)
if [[ "${INSTALLED_VERSION}" == v1.* ]]; then
    warn "WARNING: Syncthing v1.x detected. The receiveencrypted folder type requires v2.x."
    warn "Check that the candidate channel was applied and run: sudo apt-get install -y syncthing"
else
    success "Syncthing ${INSTALLED_VERSION} installed."
fi

# ── Step 3: Enable and start systemd service ──────────────────────────────────
info "Step 3/6 — Configuring systemd service..."

SERVICE_NAME="syncthing@${CURRENT_USER}"

if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    success "Service ${SERVICE_NAME} already enabled."
else
    info "Enabling ${SERVICE_NAME}..."
    sudo systemctl enable "${SERVICE_NAME}"
    success "Service enabled."
fi

if systemctl is-active --quiet "${SERVICE_NAME}"; then
    success "Service ${SERVICE_NAME} already running."
else
    info "Starting ${SERVICE_NAME}..."
    sudo systemctl start "${SERVICE_NAME}"
    success "Service started."
fi

# ── Step 4: Wait for config.xml to be generated ───────────────────────────────
info "Step 4/6 — Waiting for Syncthing to generate config.xml..."
WAIT=0
until [[ -f "${SYNCTHING_CONFIG}" ]]; do
    sleep 2
    WAIT=$((WAIT + 2))
    if [[ ${WAIT} -ge 30 ]]; then
        error "Timed out waiting for config.xml at ${SYNCTHING_CONFIG}. Check: journalctl -u ${SERVICE_NAME}"
    fi
done
success "config.xml found at ${SYNCTHING_CONFIG}"

# ── Step 5: Patch connectionLimitMax and connectionLimitEnough to 0 ───────────
info "Step 5/6 — Patching connection limits in config.xml..."

# Read current values
MAX_VAL=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('${SYNCTHING_CONFIG}')
root = tree.getroot()
options = root.find('options')
el = options.find('connectionLimitMax') if options is not None else None
print(el.text if el is not None else 'NOT_FOUND')
")

ENOUGH_VAL=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('${SYNCTHING_CONFIG}')
root = tree.getroot()
options = root.find('options')
el = options.find('connectionLimitEnough') if options is not None else None
print(el.text if el is not None else 'NOT_FOUND')
")

info "Current connectionLimitMax=${MAX_VAL}  connectionLimitEnough=${ENOUGH_VAL}"

if [[ "${MAX_VAL}" == "0" && "${ENOUGH_VAL}" == "0" ]]; then
    success "Connection limits already set to 0 — skipping patch."
else
    info "Stopping Syncthing to safely edit config.xml..."
    sudo systemctl stop "${SERVICE_NAME}"

    python3 - <<'PYEOF'
import xml.etree.ElementTree as ET
import os, shutil, sys

config_path = os.path.expandvars("${SYNCTHING_CONFIG}".replace('${SYNCTHING_CONFIG}', os.environ.get('SYNCTHING_CONFIG', '')))
# Fall back to shell-expanded value passed via heredoc scope
import subprocess
config_path = subprocess.check_output(
    "echo ${SYNCTHING_CONFIG}", shell=True, text=True
).strip()

shutil.copy2(config_path, config_path + ".bak")

ET.register_namespace('', '')
tree = ET.parse(config_path)
root = tree.getroot()
options = root.find('options')

if options is None:
    print("ERROR: <options> element not found in config.xml", file=sys.stderr)
    sys.exit(1)

for tag in ('connectionLimitMax', 'connectionLimitEnough'):
    el = options.find(tag)
    if el is None:
        el = ET.SubElement(options, tag)
    el.text = '0'

tree.write(config_path, encoding='unicode', xml_declaration=True)
print(f"Patched {config_path} (backup at {config_path}.bak)")
PYEOF

    # Use sed as a more reliable fallback for simple value replacement
    sudo sed -i 's|<connectionLimitMax>[^<]*</connectionLimitMax>|<connectionLimitMax>0</connectionLimitMax>|g' "${SYNCTHING_CONFIG}"
    sudo sed -i 's|<connectionLimitEnough>[^<]*</connectionLimitEnough>|<connectionLimitEnough>0</connectionLimitEnough>|g' "${SYNCTHING_CONFIG}"

    info "Restarting Syncthing..."
    sudo systemctl start "${SERVICE_NAME}"
    success "Connection limits patched to 0."
fi

# ── Step 6: Place .stignore in sync folder (if SYNC_FOLDER is set) ────────────
info "Step 6/6 — Ignore patterns..."

if [[ -n "${SYNC_FOLDER:-}" ]]; then
    STIGNORE_PATH="${SYNC_FOLDER}/.stignore"
    if [[ -f "${STIGNORE_PATH}" ]]; then
        success ".stignore already exists at ${STIGNORE_PATH} — not overwriting."
    else
        mkdir -p "${SYNC_FOLDER}"
        cat > "${STIGNORE_PATH}" << 'IGNORE'
**/node_modules
**/.pnpm
**/.git
**/.next
**/.nuxt
**/dist
**/build
**/.output
**/__pycache__
**/*.pyc
**/.DS_Store
**/Thumbs.db
IGNORE
        success ".stignore written to ${STIGNORE_PATH}"
    fi
else
    warn "SYNC_FOLDER not set — skipping .stignore placement."
    warn "Set it and re-run, or copy .stignore manually to your sync folder root."
    warn "Example: SYNC_FOLDER=/home/${CURRENT_USER}/sync ./install-syncthing-pi.sh"
fi

# ── Post-install checklist ────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  Setup complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Manual steps still required:"
echo ""
echo "  1. Access Syncthing GUI via SSH tunnel:"
echo "     ssh -L 8384:127.0.0.1:8384 <your-username>@<tailscale-ip>"
echo "     Then open http://127.0.0.1:8384 in your browser"
echo ""
echo "  2. Add laptop devices (from their Device IDs)"
echo "     Syncthing GUI → Add Device → paste Device ID from each laptop"
echo ""
echo "  3. Add the shared folder with type set to 'receiveencrypted'"
echo "     Syncthing GUI → Add Folder → Folder Type → Receive Encrypted"
echo "     Set an Encryption Password that matches your laptop nodes"
echo ""
echo "  4. If upgrading from plaintext sync: wipe the stale index"
echo "     sudo systemctl stop ${SERVICE_NAME}"
echo "     rm -rf ${SYNCTHING_CONFIG_DIR}/index-v2*"
echo "     sudo systemctl start ${SERVICE_NAME}"
echo ""
echo "  5. Verify Tailscale is installed and this node is authenticated:"
echo "     tailscale status"
echo ""
echo "  Docs: docs/setup-windows.md | docs/troubleshooting.md"
echo ""
