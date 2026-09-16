#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and catch pipeline failures.
set -euo pipefail

# Ensure the script is actually being run by the root user
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

# Check if the server version argument was provided
if [ $# -lt 1 ] || [ -z "$1" ]; then
    echo "Usage: $0 <SERVER_VERSION>" >&2
    echo "Example: $0 1.26.51.1" >&2
    echo "    OR: $0 bedrock-server-1.26.51.1" >&2
    exit 1
fi

# ==========================================
# CONFIGURATION & FORMATTING
# ==========================================
# If the user passed just "1.26.51.1", normalize it to "bedrock-server-1.26.51.1"
INPUT_ARG="$1"
if [[ "$INPUT_ARG" =~ ^[0-9] ]]; then
    SERVER_VERSION="bedrock-server-${INPUT_ARG}"
else
    SERVER_VERSION="${INPUT_ARG}"
fi

# Reject anything that isn't a plain "bedrock-server-<version>" token. Without
# this, SERVER_VERSION flows unchecked into rm -rf and path construction below,
# so a value like "../../etc" would let this root-run script delete arbitrary
# directories relative to BASE_DIR.
if [[ ! "$SERVER_VERSION" =~ ^bedrock-server-[0-9]+(\.[0-9]+)*$ ]]; then
    echo "[ERROR] Invalid server version: '${INPUT_ARG}'" >&2
    echo "Expected a version like 1.26.51.1 or bedrock-server-1.26.51.1" >&2
    exit 1
fi

BASE_DIR="/bedrock"
SERVICE_NAME="bedrock"
LOCK_FILE="${BASE_DIR}/.upgrade.lock"

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

# Prevent two copies of this script (e.g. a cron job and a manual run) from
# racing on the same download/extract/symlink-swap sequence.
exec 200>"$LOCK_FILE"
flock -n 200 || error_exit "Another instance of this script is already running (lock: $LOCK_FILE)."

# ==========================================
# MAIN EXECUTION
# ==========================================
log "Starting Bedrock Server update to ${SERVER_VERSION}..."

# Remember what 'current' points to so we can roll back if the new version
# fails to come up.
PREVIOUS_TARGET=""
if [ -L current ]; then
    PREVIOUS_TARGET="$(readlink current)"
fi

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

# 2. Download the new version using the corrected, validated URL schema
log "Downloading Minecraft Bedrock Server from Mojang..."
wget --quiet --show-progress "https://www.minecraft.net/bedrockdedicatedserver/bin-linux/${SERVER_VERSION}.zip" \
    || error_exit "Failed to download version from URL: https://www.minecraft.net/bedrockdedicatedserver/bin-linux/${SERVER_VERSION}.zip"

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

# Give the server a moment to come up, then confirm it's actually running
# before declaring success. 'systemctl start' only confirms the unit was
# accepted, not that bedrock_server stayed alive.
sleep 5
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    log "ERROR: ${SERVICE_NAME} failed to stay running on ${SERVER_VERSION}."
    if [ -n "$PREVIOUS_TARGET" ]; then
        log "Rolling back 'current' symlink to ${PREVIOUS_TARGET}..."
        ln -s "$PREVIOUS_TARGET" current_tmp
        mv -fT current_tmp current
        systemctl start "$SERVICE_NAME" || log "WARNING: Failed to restart service on rolled-back version."
    else
        log "WARNING: No previous version to roll back to."
    fi
    error_exit "Update to ${SERVER_VERSION} failed; see above for rollback status."
fi

# 7. Cleanup download artifact
rm -f "${SERVER_VERSION}.zip"

log "Update process complete. Checking status:"
systemctl status "$SERVICE_NAME" --no-pager
