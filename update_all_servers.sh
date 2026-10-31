#!/usr/bin/env bash
# Updates every Bedrock server to the latest Linux release Mojang publishes (or a version you
# pass in), by running /bedrock/server_upgrade.sh on each host over SSH. Run from any machine
# that can SSH to the servers as root.
#
# Usage:
#   ./update_all_servers.sh                 # latest release on all servers
#   ./update_all_servers.sh 1.26.61.1       # a specific version
#   DRY_RUN=1 ./update_all_servers.sh       # show what would happen, change nothing
#   HOSTS="192.168.1.10" ./update_all_servers.sh   # override hosts.txt for one run
#
# Servers come from hosts.txt next to this script: one host (IP or hostname) per line; blank lines
# and lines starting with # are ignored. hosts.txt is gitignored; see hosts.example.txt.
# Set HOSTS_FILE to use a different file.
#
# For each server: skips it if it already runs that version; otherwise runs server_upgrade.sh
# (which stops the service, copies server.properties and worlds/, swaps the 'current' symlink,
# and rolls back if the new version doesn't stay up). server_upgrade.sh doesn't carry over
# allowlist.json or permissions.json, so this copies them from the previous version when they
# differ, then restarts. A failure on one server doesn't stop the others.
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-$(cd "$(dirname "$0")" && pwd)/hosts.txt}"
if [[ -n "${HOSTS:-}" ]]; then
	HOSTS=($HOSTS)
elif [[ -f "$HOSTS_FILE" ]]; then
	HOSTS=()
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%%#*}"                     # strip comments
		line="$(echo "$line" | tr -d '[:space:]')"
		if [[ -n "$line" ]]; then HOSTS+=("$line"); fi
	done < "$HOSTS_FILE"
else
	echo "No servers: create $HOSTS_FILE (one host per line; see hosts.example.txt) or set HOSTS." >&2
	exit 1
fi
[[ ${#HOSTS[@]} -gt 0 ]] || { echo "No servers listed in $HOSTS_FILE." >&2; exit 1; }
SSH_USER="${SSH_USER:-root}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/bedrock/server_upgrade.sh}"
BASE_DIR="/bedrock"
LINKS_URL="https://net-secondary.web.minecraft-services.net/api/v1.0/download/links"
DRY_RUN="${DRY_RUN:-0}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

log() { echo "[$(date +'%H:%M:%S')] $*"; }

# Latest stable Linux server version from Mojang's download service (not the preview build).
latest_version() {
	curl -fsS --max-time 20 "$LINKS_URL" \
		| grep -oE 'bin-linux/bedrock-server-[0-9]+(\.[0-9]+)+\.zip' \
		| head -1 \
		| sed -E 's#bin-linux/bedrock-server-(.*)\.zip#\1#'
}

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
	VERSION="$(latest_version)" || true
	[[ -n "$VERSION" ]] || { echo "Could not determine the latest version from $LINKS_URL" >&2; exit 1; }
	log "Latest Bedrock server release: $VERSION"
fi
VERSION="${VERSION#bedrock-server-}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
TARGET="bedrock-server-$VERSION"

declare -a SUMMARY=()
FAILED=0

for host in "${HOSTS[@]}"; do
	dest="$SSH_USER@$host"
	log "===== $host"

	if ! current="$(ssh "${SSH_OPTS[@]}" "$dest" "readlink $BASE_DIR/current" 2>/dev/null)"; then
		log "Cannot connect, or $BASE_DIR/current is missing."
		SUMMARY+=("$host: FAILED (cannot connect or no $BASE_DIR/current)"); FAILED=1; continue
	fi
	current="$(basename "$current")"
	name="$(ssh "${SSH_OPTS[@]}" "$dest" "grep -m1 '^server-name=' $BASE_DIR/current/server.properties | cut -d= -f2" 2>/dev/null || true)"
	log "${name:-server} is on ${current#bedrock-server-}"

	if [[ "$current" == "$TARGET" ]]; then
		log "Already on $VERSION; skipping."
		SUMMARY+=("$host (${name:-?}): already on $VERSION"); continue
	fi

	if [[ "$DRY_RUN" == "1" ]]; then
		log "DRY RUN: would run $REMOTE_SCRIPT $VERSION, then carry over allowlist/permissions from $current."
		SUMMARY+=("$host (${name:-?}): would upgrade ${current#bedrock-server-} -> $VERSION"); continue
	fi

	log "Upgrading ${current#bedrock-server-} -> $VERSION ..."
	if ! ssh "${SSH_OPTS[@]}" "$dest" "$REMOTE_SCRIPT $VERSION"; then
		log "Upgrade script failed on $host (it rolls back to the previous version when the new one won't start)."
		SUMMARY+=("$host (${name:-?}): FAILED, see output above"); FAILED=1; continue
	fi

	# Carry over allowlist.json and permissions.json, then confirm the new version is running.
	if ! ssh "${SSH_OPTS[@]}" "$dest" "bash -s" <<EOF
set -euo pipefail
cd "$BASE_DIR"
changed=0
for f in allowlist.json permissions.json; do
	if [ -f "$current/\$f" ] && ! cmp -s "$current/\$f" "current/\$f"; then
		cp -p "$current/\$f" "current/\$f"
		echo "  carried over \$f from $current"
		changed=1
	fi
done
if [ "\$changed" = 1 ]; then
	systemctl restart bedrock
	sleep 5
fi
[ "\$(basename "\$(readlink current)")" = "$TARGET" ] || { echo "  'current' does not point to $TARGET"; exit 1; }
systemctl is-active --quiet bedrock || { echo "  bedrock service is not running"; exit 1; }
echo "  running $TARGET"
EOF
	then
		SUMMARY+=("$host (${name:-?}): upgraded, but the post-upgrade check FAILED"); FAILED=1; continue
	fi
	SUMMARY+=("$host (${name:-?}): upgraded ${current#bedrock-server-} -> $VERSION")
done

echo
log "Summary:"
printf '  %s\n' "${SUMMARY[@]}"
exit "$FAILED"
