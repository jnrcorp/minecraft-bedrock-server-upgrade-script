#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and catch pipeline failures.
set -euo pipefail

# Ensure the script is actually being run by the root user
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

# ==========================================
# CONFIGURATION
# ==========================================
SERVER_VERSION="bedrock-server-1.26.51.1"
BASE_DIR="/bedrock"
SERVICE_NAME="bedrock"

# ==========================================
# HELPER FUNCTIONS
# ==========================================
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "ERROR: $1" >&2
    exit 1
}

# Ensure we run from the correct directory
cd "$BASE_DIR" || error_exit "Could not change directory to $BASE_DIR"

# ==========================================
# MAIN EXECUTION
# ==========================================
log "Starting Bedrock Server update to ${SERVER_VERSION}..."

# 1. Stop the service safely
log "Stopping ${SERVICE_NAME} service..."
if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl stop "$SERVICE_NAME"
else
    log "Service ${SERVICE_NAME} was not running. Proceeding..."
fi

# Clean up any leftover partial downloads or half-extracted folders from prior failed runs
rm -f "${SERVER_VERSION}.zip"
rm -rf "${SERVER_VERSION}"

# 2. Download the new version using your exact URL schema
log "Downloading Minecraft Bedrock Server..."
wget --quiet --show-progress "https://www.minecraft.net/bedrockdedicatedserver/bin-linux/${SERVER_VERSION}.zip" \
    || error_exit "Failed to download version ${SERVER_VERSION}.zip"

# 3. Extract the server files
log "Extracting files..."
unzip -q "${SERVER_VERSION}.zip" -d "${SERVER_VERSION}" \
    || error_exit "Failed to unzip ${SERVER_VERSION}.zip"

# 4. Copy configurations and world data from the active link
if [ -d "current" ]; then
    log "Migrating configuration and worlds from 'current' symlink..."
    
    if [ -f "current/server.properties" ]; then
        cp -p "current/server.properties" "${SERVER_VERSION}/"
    else
        log "WARNING: No existing server.properties found to migrate."
    fi

    mkdir -p "${SERVER_VERSION}/worlds"
    if [ -d "current/worlds" ] && [ "$(ls -A current/worlds)" ]; then
        # -r: recursive, -n: do not overwrite existing files, -p: preserve permissions/timestamps
        cp -rnp current/worlds/* "${SERVER_VERSION}/worlds/"
    else
        log "No existing worlds found to migrate."
    fi
else
    log "No 'current' directory/symlink found. Skipping data migration (Fresh Install)."
    mkdir -p "${SERVER_VERSION}/worlds"
fi

# 5. Atomic symlink replacement (Zero-downtime switchover)
log "Updating 'current' symlink to point to ${SERVER_VERSION}..."
ln -s "${SERVER_VERSION}" current_tmp
mv -fT current_tmp current

# 6. Start service and check status
log "Starting ${SERVICE_NAME} service..."
systemctl start "$SERVICE_NAME"

# 7. Cleanup download artifact
rm -f "${SERVER_VERSION}.zip"

log "Update process complete. Checking status:"
systemctl status "$SERVICE_NAME" --no-pager
