# deploy-pool-nhl

The production stack for [slapshot.xyz](https://slapshot.xyz): Caddy, the
[frontend](https://github.com/jcorriveau23/frontend-pool-nhl), the
[rust backend](https://github.com/jcorriveau23/backend-pool-nhl), the
[scrapers](https://github.com/jcorriveau23/script-pool-nhl), mongo and redis on
a single host.

Nothing is built here. Each application repo builds its own image on release and
pushes it to GHCR; this repo only pins which tag runs, how the services reach
each other, and what is exposed to the internet.

## Server setup

A 2 vCPU / 4 GB VPS is enough for the whole stack. On a fresh Debian host:

```bash
# Docker
curl -fsSL https://get.docker.com | sh

# The stack lives here — the deploy workflows cd into this path.
sudo mkdir -p /srv/slapshot
sudo chown "$USER" /srv/slapshot
git clone https://github.com/jcorriveau23/deploy-pool-nhl /srv/slapshot
```

Point the `slapshot.xyz` and `www.slapshot.xyz` A records at the host, then:

```bash
cd /srv/slapshot
docker compose up -d
```

Caddy issues the TLS certificates on first start, which needs ports 80 and 443
reachable from the internet.

If the GHCR packages are private, authenticate once so `docker compose pull`
works — a classic PAT with `read:packages` is enough:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u jcorriveau23 --password-stdin
```

Making the three packages public is simpler and avoids the token expiring.

## Migrating off the old setup

Until this stack existed, slapshot.xyz ran on a desktop: nginx with certbot
terminating TLS, `next start` and `target/release/poolnhl_app` started by hand
in terminals, and mongo + redis in the backend repo's dev compose.

The database is the only thing that has to move. It is small — ~25 MB of data,
23k players, 14 pools — so the dump is a few seconds:

```bash
# On the desktop, from the running mongo container
docker exec backend-pool-nhl-mongo-1 mongodump --db=hockeypool \
  --gzip --archive=/tmp/hockeypool.archive.gz
docker cp backend-pool-nhl-mongo-1:/tmp/hockeypool.archive.gz .

# Onto the server
scp hockeypool.archive.gz user@server:/tmp/
ssh user@server 'cd /srv/slapshot \
  && docker compose cp /tmp/hockeypool.archive.gz mongo:/tmp/ \
  && docker compose exec -T mongo mongorestore --drop --gzip \
       --archive=/tmp/hockeypool.archive.gz \
  && docker compose restart backend'
```

The restart is what rebuilds the indexes. `mongorestore --drop` drops each
collection before restoring it, taking its indexes with it, and recreates only
the ones carried in the dump's own metadata. The backend calls `init_indexes`
for pools, players and daily leaders on every start, and `createIndex` is
idempotent, so restarting it is enough — and is the same step whether or not
the dump happened to carry them.

Redis does not need migrating. It holds live draft-room state keyed with hash
TTLs, which is rebuilt as rooms are used — just do not cut over while a draft is
in progress.

Certificates do not migrate either. Caddy issues its own on first start, which
it can only do once `slapshot.xyz` resolves to the server, so the order is:
lower the DNS TTL a day ahead, bring the stack up, restore the dump, then move
the A records. Caddy picks up the certificate within seconds of the DNS
change. Keep the desktop's nginx and certbot in place until the new host has
served traffic for a day, then retire them.

The `day_leaders_backfill_test` collection in the live database is a leftover
from a backfill test. It is not read by anything and is worth dropping before
the dump rather than carrying it over.

## Deployments

Publishing a GitHub release in any of the three application repos builds the
image, pushes it to GHCR, then SSHes here to pull and restart only that service.
Each repo needs three secrets:

| Secret | Value |
| --- | --- |
| `DEPLOY_HOST` | the server's IP or hostname |
| `DEPLOY_USER` | the SSH user that owns `/srv/slapshot` |
| `DEPLOY_SSH_KEY` | private half of a keypair whose public half is in that user's `authorized_keys` |

Changes to this repo — a new Caddy route, a changed env var — are applied by
pulling and running compose on the host:

```bash
cd /srv/slapshot && git pull && docker compose up -d
```

## Running a one-shot scraper job

The scrapers ship as one image. The daemon is the default command but is held
behind the `scrapers` compose profile and does not start with the stack, pending
an arm64 build of the image — bring it up with
`docker compose --profile scrapers up -d` once that exists. The one-shot jobs
run regardless of the profile:

```bash
docker compose run --rm scraper nhl-cumulate-stats
docker compose run --rm scraper nhl-active-players
docker compose run --rm scraper nhl-daily-leaders --start 2026-03-01 --end 2026-03-12
```

## Backups

Mongo holds every pool and all season history, and nothing else does. A nightly
dump to the host, kept for a week:

```cron
0 4 * * * cd /srv/slapshot && docker compose exec -T mongo mongodump --db=hockeypool --gzip --archive > /srv/backups/hockeypool-$(date +\%F).gz
```

Copy those off the host — a backup that only exists on the machine it protects
is not a backup.
