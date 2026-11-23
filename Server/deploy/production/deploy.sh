#!/bin/sh
# Deploys the backend to one server over SSH (plan section 13, deployment).
#   Server/deploy/production/deploy.sh root@203.0.113.10 api.example.com com.example.farside
# The server needs Docker with the compose plugin (the DigitalOcean Docker image has both).
# The first run writes .env on the server with fresh secrets; the Cloudflare TURN key id and
# token are left for you to paste there. Later runs keep .env as it is.
set -eu
host=$1
domain=$2
bundle_prefix=$3
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)

rsync -az --delete \
  --exclude vendor --exclude .env --exclude 'storage/logs/*' --exclude 'storage/framework/*/*' \
  --exclude database/database.sqlite \
  "$root/Server/api/" "$host:/opt/farside/Server/api/"
rsync -az --exclude .env "$here/" "$host:/opt/farside/Server/deploy/production/"

ssh "$host" sh -s "$domain" "$bundle_prefix" <<'REMOTE'
set -eu
domain=$1
prefix=$2
cd /opt/farside/Server/deploy/production
if [ ! -f .env ]; then
  rand() { openssl rand -hex "$1"; }
  sed -e "s|^FARSIDE_DOMAIN=.*|FARSIDE_DOMAIN=$domain|" \
      -e "s|^APP_URL=.*|APP_URL=https://$domain|" \
      -e "s|^APP_KEY=.*|APP_KEY=base64:$(openssl rand -base64 32)|" \
      -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$(rand 24)|" \
      -e "s|^REVERB_APP_ID=.*|REVERB_APP_ID=$(od -An -N3 -tu4 /dev/urandom | tr -d ' ')|" \
      -e "s|^REVERB_APP_KEY=.*|REVERB_APP_KEY=$(rand 10)|" \
      -e "s|^REVERB_APP_SECRET=.*|REVERB_APP_SECRET=$(rand 24)|" \
      -e "s|^APPLE_AUDIENCES=.*|APPLE_AUDIENCES=$prefix.client,$prefix.host|" \
      env.example > .env
  chmod 600 .env
  echo "Wrote .env. Paste CLOUDFLARE_TURN_KEY_ID and CLOUDFLARE_TURN_API_TOKEN into $(pwd)/.env, then deploy again."
fi
docker compose --env-file .env up -d --build
docker compose ps --format '{{.Service}} {{.State}}'
REMOTE

echo "Health: $(curl -s -o /dev/null -w '%{http_code}' "https://$domain/up" || true)"
