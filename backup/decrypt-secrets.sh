#!/bin/bash
set -e
cd "$(dirname "$0")"

ENCRYPTED="../secrets/discord-webhook.enc.txt"
DECRYPTED=".secrets/notifications.url"

mkdir -p .secrets
sops -d "$ENCRYPTED" | tr -d '\n' > "$DECRYPTED"
chmod 600 "$DECRYPTED"
