# minecraft-bedrock-server-upgrade-script
A bash script to upgrade your server to the latest

This script assumes the following:

1. You are using ubunut.
2. You have the start/stop configured through a service (e.g. `/etc/systemd/system/bedrock.service`, see the file in this repo)
3. You keep a history of all your server and symlink the current one to the directory you are running. (e.g. `current -> ./bedrock-server-1.26.51.1`)
