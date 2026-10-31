# minecraft-bedrock-server-upgrade-script
A bash script to upgrade your server to the latest

This script assumes the following:

1. You are using ubuntu.
2. You are running as the root user (or understand how to change this script if you are not and need to make adjustements).
3. You have the start/stop configured through a service (e.g. `/etc/systemd/system/bedrock.service`, see the file in this repo)
4. You keep a history of all your server and symlink the current one to the directory you are running. (e.g. `current -> ./bedrock-server-1.26.51.1`)

## Updating several servers at once

`update_all_servers.sh` runs `server_upgrade.sh` on every server listed in `hosts.txt`, over SSH as root.
Run it from any machine that can SSH to the servers.

1. Copy `hosts.example.txt` to `hosts.txt` and list your servers, one per line (IP or hostname).
   `hosts.txt` is gitignored.
2. Put `server_upgrade.sh` on each server at `/bedrock/server_upgrade.sh`.
3. Run it:

```sh
./update_all_servers.sh              # latest stable release from Mojang, on every server
DRY_RUN=1 ./update_all_servers.sh    # show what would happen, change nothing
./update_all_servers.sh 1.26.61.1    # a specific version
HOSTS="192.168.1.10" ./update_all_servers.sh   # just these servers, ignoring hosts.txt
```

What it does on each server:
- **Skips** servers that already run the target version.
- **Upgrades** the rest with `server_upgrade.sh`, which rolls back if the new version won't start.
- **Copies** `allowlist.json` and `permissions.json` from the previous version if they changed, then restarts.
  `server_upgrade.sh` only carries over `server.properties` and `worlds/`.
- **Checks** that `current` points to the new version and the service is running.

A failure on one server doesn't stop the others. It prints a summary at the end and exits with
code 1 if anything failed.
