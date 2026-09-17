# OpenProject on DigitalOcean

One Droplet running the app, DigitalOcean Managed PostgreSQL holding the data, Caddy for TLS.
There is no database to operate: DigitalOcean takes daily backups with 7-day point-in-time recovery.

| Piece | Default | About USD a month |
|---|---|---|
| Droplet `s-2vcpu-4gb`, Frankfurt, weekly image backups | app, worker, Caddy | 24 + 4.80 |
| Managed PostgreSQL 17 `db-s-1vcpu-1gb`, same VPC | 22 connections | 15 |

For 20 or more active users move to `s-4vcpu-8gb` (48) and `db-s-1vcpu-2gb` (30). Both are resizes in the
control panel, not migrations.

## Which image

`OPENPROJECT_IMAGE` in `.env` decides what runs.

- **Official Community image, the default:** `openproject/openproject:17-slim`. Nothing to build.
  AI access works through an external MCP adapter against the REST API, see the repository's MCP setup notes.
- **This fork's code:** run the "Build fork image" workflow (Actions tab, manual), then set
  `OPENPROJECT_IMAGE=ghcr.io/<owner>/openproject:<tag>`. For a private package, run
  `docker login ghcr.io` on the Droplet once with a read-only token.

## First deployment

1. Install and log in: `brew install doctl && doctl auth init`. Upload an SSH key in the control panel,
   find its id with `doctl compute ssh-key list`.
2. Create the resources. This spends money and asks for confirmation:
   `SSH_KEY_ID=<id> ./provision.sh`
   It writes `.env` next to this file with a generated `SECRET_KEY_BASE`, the private database URL and an
   initial admin password. The file is git-ignored and mode 600. Nothing secret is printed.
3. Point a DNS A record for your host name at the printed IP. Caddy needs it to obtain a certificate.
4. Edit `.env`: set `OPENPROJECT_HOST__NAME` and the SMTP block.
5. Copy and start, as printed by the script:
   ```
   scp docker-compose.yml Caddyfile .env bootstrap-db.sh deploy.sh backup.sh root@<ip>:/srv/openproject/
   ssh root@<ip> 'cd /srv/openproject && ./bootstrap-db.sh && ./deploy.sh'
   ```
   The first start loads the schema into the empty database and can take several minutes.
6. Log in as `admin` with the password from `.env`, then remove `OPENPROJECT_SEED__ADMIN__USER__PASSWORD`
   from the server's `.env`. Put `SECRET_KEY_BASE` in your password manager.
7. Install the nightly portable backup (the line is at the top of `backup.sh`), and run one restore drill
   before the team depends on it.

## Updating

Change the tag in `OPENPROJECT_IMAGE`, run `./deploy.sh`. The seeder container migrates the database before
web and worker start. Rolling back is the previous tag plus `./deploy.sh`, as long as the newer version's
migrations were backwards compatible; otherwise restore the database to the point before the update.

## Restoring

- **Database, point in time:** DigitalOcean control panel, database, Backups, "Restore to new cluster",
  then put the new cluster's private URL into `.env` and run `./deploy.sh`.
- **Database, from a portable dump:**
  `docker run --rm -i postgres:17 pg_restore --no-owner -d "<url>" < db-YYYY-MM-DD.dump`
- **Attachments:** `docker run --rm -v openproject_assets:/assets -v /var/backups/openproject:/in alpine tar -xzf /in/assets-YYYY-MM-DD.tar.gz -C /assets`
- **Whole server:** restore the weekly Droplet backup, or create a fresh Droplet with `cloud-init.yml`
  and repeat step 5. The Droplet holds nothing that cannot be recreated except the attachments volume.

## Things that bite

- `OPENPROJECT_HOST__NAME` must match the public name exactly, and the proxy must speak HTTPS, or logins loop.
- The 1 GiB database allows 22 connections. The thread settings in `.env.example` are sized for that;
  raise them only together with the database plan.
- `bootstrap-db.sh` creates `pg_trgm`, `btree_gist` and `unaccent` up front. OpenProject's schema file asks
  for them in `pg_catalog`, which a managed database's admin user may not be allowed to do; with the
  extensions already present those statements are no-ops. This has not been exercised against a live
  DigitalOcean cluster yet. If the first `seeder` run fails, its log (`docker compose logs seeder`) says why.
- Use the private database host (the script does). The public one also works but leaves the VPC.
- Mail is sent by the worker. `/health_checks/mail` tells you whether SMTP works.
- Size and database slugs in `provision.sh` are DigitalOcean's names at the time of writing. If the API
  rejects one, list current ones with `doctl compute size list` and `doctl databases options slugs --engine pg`.
