# Deploying the backend

Plan section 13. Two setups:

- **Local**, `make server-up`: `compose.yml` here. API on :47880, Reverb on :47881, and a small
  coturn relay for testing Relay only on the network.
- **Public**, `make server-deploy`: `production/`. One server, Caddy with TLS from Let's Encrypt,
  the API and Reverb on one name, PostgreSQL and Redis private, Cloudflare for the relay.

## First public deploy

1. Create a droplet from DigitalOcean's Docker image (1 GB is enough), with your SSH key.
2. Point a DNS A record, such as `farside-api.example.com`, at it. Open ports 80 and 443 only.
3. `make server-deploy HOST=root@<droplet ip> DOMAIN=<that name>`. The first run writes
   `/opt/farside/Server/deploy/production/.env` with fresh secrets.
4. In Cloudflare: Realtime, TURN Server, Create. Paste the key id and API token into that `.env`
   as `CLOUDFLARE_TURN_KEY_ID` and `CLOUDFLARE_TURN_API_TOKEN`, then run step 3 again.
5. Point the apps at it in `Config/Local.xcconfig`, writing `//` as `/$()/` because xcconfig
   reads `//` as a comment:

       FARSIDE_API_URL = https:/$()/<name>
       FARSIDE_REVERB_URL = wss:/$()/<name>
       FARSIDE_REVERB_KEY = <REVERB_APP_KEY from the server's .env>

Later deploys run step 3 again; `.env` is kept. Nightly database dumps arrive with Phase 4's
operations work.
