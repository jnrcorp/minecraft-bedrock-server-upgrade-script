# minecraft-bedrock-server-upgrade-script
A bash script to upgrade your server to the latest

This script assumes the following:

1. You are using ubuntu.
2. You are running as the root user (or understand how to change this script if you are not and need to make adjustements).
3. You have the start/stop configured through a service (e.g. `/etc/systemd/system/bedrock.service`, see the file in this repo)
4. You keep a history of all your server and symlink the current one to the directory you are running. (e.g. `current -> ./bedrock-server-1.26.51.1`)
