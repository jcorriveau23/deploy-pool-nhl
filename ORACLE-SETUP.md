# Hosting slapshot.xyz on Oracle Cloud Always Free

Target: one `VM.Standard.A1.Flex` instance (Ampere ARM) in `ca-montreal-1`,
running the same `docker-compose.yml` as any other host. Cost: $0/month.

The Always Free ARM allowance was cut from 4 OCPU / 24 GB to **2 OCPU / 12 GB**
on 15 June 2026, with over-limit instances terminated from 18 August 2026. Stay
at or under 2 OCPU / 12 GB. That is still ~10x what this stack needs — the six
containers idle at roughly 700 MB - 1 GB resident in total.

---

## Step 0 — Prerequisite: arm64 images

**This is blocking.** Ampere A1 is `aarch64`, and the application images on GHCR
were originally `linux/amd64` only. Status as of 23 August 2026:

| Image | arm64 | |
| --- | --- | --- |
| `new-frontend-pool-nhl` | yes | released |
| `backend-pool-nhl` | yes | **needs one more release** — see below |
| `script-pool-nhl` | no | out of scope; held behind a compose profile |

**The backend needs re-releasing before this compose file is applied.** The
config file source in `settings.rs` is now optional, and `docker-compose.yml`
here no longer mounts `./config` — every setting arrives as an `APP_*` env var
instead, so there is one place to read and no second copy of `release.json` to
drift against the one in `backend-pool-nhl`.

The currently published image predates that change and still treats the file as
mandatory. Running it against this compose file aborts immediately with:

```
Could not parse settings: configuration file "config/release" not found
```

So the order is: publish the backend release first, then bring the stack up.
On an already-running host the same applies — `git pull` here without a matching
backend image will take the service down on the next `up -d`.

The two images the site serves from are ready, which is enough to migrate.

The scraper is deferred. Its `release.yaml` is already converted, so finishing
it later is just publishing a release — but until then it is behind the
`scrapers` profile in `docker-compose.yml` and does not start. That is
deliberate: it is `restart: unless-stopped`, so an amd64-only image on an ARM
host crash-loops with an exec format error while every other service comes up
around it, giving you a site that looks healthy while nothing refreshes.

**What is not running while it is off:** daily leaders (every 3 min), injury
scraping (hourly), and the on-demand `nhl-cumulate-stats` / `nhl-active-players`
jobs. Pool scoring does not advance. This is survivable through the offseason
but has to be fixed before the season opens in October.

The one-shot jobs still work when you need them — `docker compose run` starts a
profiled service regardless:

```bash
docker compose run --rm scraper nhl-cumulate-stats
```

To bring the daemon back once an arm64 image exists:

```bash
docker compose --profile scrapers up -d
```

Verify any of them at any time with:

```bash
docker buildx imagetools inspect ghcr.io/jcorriveau23/backend-pool-nhl:latest
```

That command needs the package to be readable. `script-pool-nhl` is currently
the only private one of the three — see the note at the end of this step.

The Dockerfiles need no changes — `rust:slim-bookworm`, `python:3.13-slim-bookworm`
and `debian:bookworm-slim` all publish arm64. Only the release workflows do.

Build each architecture on its own native runner rather than emulating arm64
with QEMU. Emulated `cargo build --release` on the Rust backend runs 30-60+
minutes and can hit the job timeout; native arm64 runners are free for public
repositories.

Keeping amd64 alongside arm64 is deliberate insurance: if Oracle reclaims the
free tier, you can move to an x86 host without touching CI again.

Replace the `build-and-push` job in each repo's `.github/workflows/release.yaml`
with the two jobs below. The `deploy` job stays as it is, except that its
`needs:` becomes `merge`.

```yaml
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: linux/amd64
            runner: ubuntu-latest
          - platform: linux/arm64
            runner: ubuntu-24.04-arm
    runs-on: ${{ matrix.runner }}
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7

      - name: Prepare platform slug
        run: echo "PLATFORM_PAIR=${platform//\//-}" >> "$GITHUB_ENV"
        env:
          platform: ${{ matrix.platform }}

      - uses: docker/setup-buildx-action@v4

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v6
        with:
          images: ghcr.io/${{ github.repository }}

      # push-by-digest: each arch is pushed as an unnamed manifest. The merge
      # job below ties them together under the real tags.
      - id: build
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: ${{ matrix.platform }}
          labels: ${{ steps.meta.outputs.labels }}
          outputs: type=image,name=ghcr.io/${{ github.repository }},push-by-digest=true,name-canonical=true,push=true
          # Scoped per platform, otherwise the two legs evict each other.
          cache-from: type=gha,scope=${{ matrix.platform }}
          cache-to: type=gha,mode=max,scope=${{ matrix.platform }}

      - name: Export digest
        run: |
          mkdir -p /tmp/digests
          digest="${{ steps.build.outputs.digest }}"
          touch "/tmp/digests/${digest#sha256:}"

      - uses: actions/upload-artifact@v4
        with:
          name: digests-${{ env.PLATFORM_PAIR }}
          path: /tmp/digests/*
          if-no-files-found: error
          retention-days: 1

  merge:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: /tmp/digests
          pattern: digests-*
          merge-multiple: true

      - uses: docker/setup-buildx-action@v4

      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v6
        with:
          images: ghcr.io/${{ github.repository }}
          tags: |
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=raw,value=latest

      - name: Create manifest list and push
        working-directory: /tmp/digests
        run: |
          docker buildx imagetools create \
            $(jq -cr '.tags | map("-t " + .) | join(" ")' <<< "$DOCKER_METADATA_OUTPUT_JSON") \
            $(printf 'ghcr.io/${{ github.repository }}@sha256:%s ' *)
```

If the repos are private, `ubuntu-24.04-arm` is billed rather than free. The
low-effort alternative is a single job with `platforms: linux/amd64,linux/arm64`
plus `docker/setup-qemu-action@v3` — fine for the Python scraper, slow for Rust.

Cut a release in each of the three repos and confirm `imagetools inspect` now
lists `linux/arm64`. **Do not provision the server until it does** — the stack
cannot start otherwise.

Note: the `script-pool-nhl` GHCR package is currently private while the other
two are public. Making it public keeps `docker compose pull` working without a
PAT that expires.

---

## Step 1 — Provision the instance

In the OCI console, region **Canada Southeast (Montreal)** — set this in the
top-right region picker before anything else.

**Compute → Instances → Create instance**

| Field | Value |
| --- | --- |
| Image | Canonical Ubuntu 24.04 (**aarch64** build) |
| Shape | `VM.Standard.A1.Flex`, **2 OCPU / 12 GB** |
| Boot volume | 50 GB (free allowance is 200 GB across at most 2 volumes) |
| VNIC | public subnet, **assign a public IPv4** |
| SSH keys | paste your public key |

Two things that reliably go wrong here:

- **"Out of host capacity."** The free A1 shapes are heavily contested. Retry,
  and try each availability domain in the region. Montreal is usually less
  contested than the US and EU regions.
- **The public IP defaults to ephemeral.** A stop/start then hands you a new
  address, breaking both DNS and the `DEPLOY_HOST` secret in three repos. After
  the instance is up, go to its VNIC → IPv4 addresses → edit the public IP and
  convert it to **reserved**.

Consider upgrading the tenancy to Pay-As-You-Go once created. It stays $0 while
you remain inside the free limits, and it exempts you from the idle-instance
reclamation that applies to Always Free tenancies.

## Step 2 — Open ports 80 and 443, in both places

This is the single most common Oracle failure, because there are two firewalls
and the console only shows you one.

**a. The cloud security list.** Networking → VCN → your subnet → its security
list → Add ingress rules:

| Source CIDR | Protocol | Dest port |
| --- | --- | --- |
| `0.0.0.0/0` | TCP | 80 |
| `0.0.0.0/0` | TCP | 443 |
| `0.0.0.0/0` | UDP | 443 |

The UDP rule is for HTTP/3 — your compose file publishes `443:443/udp`, so
without it Caddy advertises QUIC that never connects.

**b. The host firewall.** Oracle's Ubuntu images ship with persisted iptables
rules that reject inbound traffic other than SSH. SSH in and check:

```bash
sudo iptables -L INPUT -n --line-numbers
```

If you see a catch-all `REJECT`, insert the allows above it and persist them:

```bash
sudo iptables -I INPUT 6 -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 7 -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT 8 -p udp --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

Adjust the line numbers so the rules land *before* the REJECT — `--line-numbers`
above tells you where it is.

## Step 3 — Host setup

Identical to the README's Debian instructions; Ubuntu changes nothing.

This repo has to exist on GitHub before the clone below works, and before the
`deploy` job in any of the three application repos can `cd /srv/slapshot &&
git pull` to pick up a compose change. It is committed locally but has no
remote yet. Create it and push:

```bash
cd /srv/slapshot   # or wherever this working copy lives
git remote add origin git@github.com:jcorriveau23/deploy-pool-nhl.git
git push -u origin master
```

Public is the simpler choice: it contains no secrets — the Hanko JWKS URL in
`docker-compose.yml` is public by design — and a private repo means the server
needs a deploy key or PAT just to clone and pull it.

Then, on the host:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out and back in for this to take effect

sudo mkdir -p /srv/slapshot
sudo chown "$USER" /srv/slapshot
git clone https://github.com/jcorriveau23/deploy-pool-nhl /srv/slapshot
```

12 GB of RAM means no swap file and no WiredTiger cache tuning are needed.

## Step 4 — Cutover

The ordering is the one already in the README, and the constraint driving it is
that Caddy cannot issue a certificate until `slapshot.xyz` resolves to this box.

1. **A day ahead:** drop the TTL on the `slapshot.xyz` and `www` A records to
   300s. Drop `day_leaders_backfill_test` from the live database — it is a
   leftover from a backfill test and not worth carrying over.

2. **Start the stack** (certificates will fail for now — expected):
   ```bash
   cd /srv/slapshot && docker compose up -d
   ```

3. **Restore the database** from the desktop:
   ```bash
   docker exec backend-pool-nhl-mongo-1 mongodump --db=hockeypool \
     --gzip --archive=/tmp/hockeypool.archive.gz
   docker cp backend-pool-nhl-mongo-1:/tmp/hockeypool.archive.gz .
   scp hockeypool.archive.gz ubuntu@<reserved-ip>:/tmp/

   ssh ubuntu@<reserved-ip> 'cd /srv/slapshot \
     && docker compose cp /tmp/hockeypool.archive.gz mongo:/tmp/ \
     && docker compose exec -T mongo mongorestore --drop --gzip \
          --archive=/tmp/hockeypool.archive.gz \
     && docker compose restart backend'
   ```

   The restart rebuilds the indexes. `mongorestore --drop` drops each
   collection and its indexes, restoring only what the dump's metadata
   carried; the backend recreates all of them on startup and `createIndex`
   is idempotent.

4. **Move the A records** to the reserved IP. Caddy picks up the certificate
   within seconds. Watch it:
   ```bash
   docker compose logs -f caddy
   ```

5. **Verify** — headers, both proxied routes, and the scraper's shared file:
   ```bash
   curl -I https://slapshot.xyz
   curl -s https://slapshot.xyz/api-rust/... | head
   curl -s https://slapshot.xyz/injured-players.json | head -c 200
   ```

   With the scraper off, that last one is served by the frontend's baked-in
   copy rather than from the shared volume — a stale list, not a 404. The
   Caddyfile falls back to the frontend whenever the volume file is absent,
   and switches back to the volume automatically the moment the scraper
   writes one.

Do not cut over mid-draft. Redis draft-room state is not migrated — it rebuilds
as rooms are used, but an in-flight draft would be dropped.

## Step 5 — Afterwards

- **Update `DEPLOY_HOST`** to the reserved IP in all three application repos,
  and set `DEPLOY_USER` to `ubuntu`. Add the deploy key's public half to
  `~/.ssh/authorized_keys` on the new host.
- **Move backups off the host.** The README's cron writes to `/srv/backups` on
  the machine it protects. The dump is ~25 MB gzipped, which fits free tiers at
  both Cloudflare R2 (10 GB) and Backblaze B2 (10 GB):
  ```cron
  0 4 * * * cd /srv/slapshot && docker compose exec -T mongo mongodump --db=hockeypool --gzip --archive > /srv/backups/hockeypool-$(date +\%F).gz && rclone copy /srv/backups/hockeypool-$(date +\%F).gz r2:slapshot-backups/
  ```
- **Keep the desktop's nginx and certbot** in place for a day after the new host
  has served traffic, then retire them.

## Rollback

Point the A records back at the desktop. That is why the TTL comes down first.

Beyond that, the recovery story here is genuinely cheap, which is what makes a
free tier an acceptable risk: images live in GHCR, configuration is this repo,
and the only state is a ~25 MB Mongo volume. Rebuilding on any other host is
`git clone`, `docker compose up -d`, `mongorestore` — Steps 1 through 4 minus
the DNS wait.
