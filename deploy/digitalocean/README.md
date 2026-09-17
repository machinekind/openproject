# OpenProject on DigitalOcean

One Droplet running the app, DigitalOcean Managed PostgreSQL holding the data, Caddy for TLS.
There is no database to operate: DigitalOcean takes daily backups with 7-day point-in-time recovery.

| Piece | Default | About USD a month |
|---|---|---|
| Droplet `s-2vcpu-4gb`, Frankfurt, weekly image backups | app, worker, Caddy | 24 + 4.80 |
| Managed PostgreSQL 17 `db-s-1vcpu-1gb`, same VPC | 22 connections | 15.15 |

This sizing matches upstream's "small instance" profile (up to 200 users with low concurrent activity), so
it carries a team of 20 to 30. Upstream places 8 GB at around 500 users. A 2 GB Droplet is not viable: the
web and worker processes alone need about 2.6 GB, and a deploy peaks near 3.2 GB while the seeder migrates.

Resize on measured signals, not on headcount: sustained swap use (`free -m`), load average staying above 2,
or a failing `/health_checks/worker_backed_up`. The next steps are `s-4vcpu-8gb` (48) and `db-s-1vcpu-2gb`
(30.45). Both are resizes in the control panel, not migrations. Do not enable DigitalOcean's connection
pooler: GoodJob needs session-level advisory locks and LISTEN/NOTIFY, which transaction pooling breaks.

## Which image

`OPENPROJECT_IMAGE` in `.env` decides what runs. It has no default.

- **This fork's image, the normal case.** The fork enables the built-in MCP server without an Enterprise
  token and adds project, group, user and membership tools. That code only exists in an image built from
  the fork. Run the "Build fork image" workflow (Actions tab, manual, pick the branch to build), then set
  `OPENPROJECT_IMAGE=ghcr.io/machinekind/openproject:<tag>` with the tag from the workflow summary.
  GHCR packages start private: either make the package public, or run `docker login ghcr.io` on the
  Droplet once with a token that has `read:packages`.
- **The official image**, `openproject/openproject:<version>-slim`, runs on this stack unchanged. Its
  `/mcp` endpoint answers 404 without a licence.

### Build from a stable base, not from `dev`

The fork's `dev` follows upstream's development line, which is an unreleased major version. Its database
migrations are ahead of every official release, so a production database created from it cannot move to an
official image later, and it carries unreleased bugs. Build production images from a branch that is an
upstream release tag plus the fork's commits. Replaying the fork's commits onto `v17.8.0` needed one
trivial conflict resolution in `config/initializers/mcp.rb`. Pin the image tag; update by building a new
tag and changing `.env`.

## MCP in production

- The endpoint is `https://<host>/mcp`. Caddy proxies it like any other path.
- Each person authenticates as themselves, with a personal API token (Basic auth, user `apikey`) or, for
  shared clients, OAuth with the `mcp` scope. Their OpenProject permissions apply to every tool call.
- The server and each tool can be switched off under Administration, AI, Model Context Protocol.
  `create_user` is the sensitive one; it still requires the user-management permission.
- The seeder step of every deploy creates the configuration rows for new tools, so tools added by an image
  update appear without manual work.
- See `MCP_SETUP.md` in the repository root for client configuration.

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
