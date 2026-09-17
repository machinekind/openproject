# OpenProject on DigitalOcean

One Droplet runs the app. DigitalOcean Managed PostgreSQL holds the data, with daily backups and 7-day
point-in-time recovery. Caddy provides TLS.

| Piece | Default | About USD a month |
|---|---|---|
| Droplet `s-2vcpu-4gb`, Frankfurt, daily image backups (30%) | app, worker, Caddy | 24 + 7.20 |
| Managed PostgreSQL 17 `db-s-1vcpu-1gb`, same VPC | 22 connections | 15.15 |

`doctl` enables daily Droplet backups by default. Weekly backups cost 20% instead of 30%; add
`--backup-policy-plan weekly` to the `droplet create` call in `provision.sh` if you prefer them. Keep daily
until an off-server backup remote is configured, because attachments live only on the Droplet.

This sizing matches upstream's "small instance" profile (up to 200 users with low concurrent activity), so
it carries a team of 20 to 30. A 2 GB Droplet is not viable: web and worker need about 2.6 GB, and a deploy
peaks near 3.2 GB while the seeder migrates.

Resize on measured signals: sustained swap use (`free -m`), load average above 2, or the worker falling
behind. The next steps are `s-4vcpu-8gb` (48) and `db-s-1vcpu-2gb` (30.45). Both are resizes in the control
panel. Do not enable DigitalOcean's connection pooler: GoodJob needs session-level advisory locks and
LISTEN/NOTIFY, which transaction pooling breaks.

## The image

`OPENPROJECT_IMAGE` in `.env` decides what runs. It has no default.

This fork enables the built-in MCP server without an Enterprise token and adds project, group, user and
membership tools. That code exists only in an image built from the fork. The official image,
`openproject/openproject:<version>-slim`, runs on this stack unchanged, but its `/mcp` answers 404.

Build with the "Build fork image" workflow. It runs from the default branch and checks out the ref you name:

```
gh workflow run fork-image.yml --ref dev -f ref=stable-17.8-mcp -f tag=17.8.0-mcp.1
```

The run summary prints one line, `OPENPROJECT_IMAGE=ghcr.io/...:<tag>@sha256:<digest>`. Copy it whole. The
digest pins the exact image; a tag alone can be overwritten by anyone with write access to the repository.
GHCR packages start private. Either make the package public, or run `docker login ghcr.io` on the Droplet
once with a token that has only `read:packages`. If that token expires, the running site is unaffected,
but the next deploy fails at the pull until you log in again.

**Only build with the workflow.** A local `docker build` copies the working tree, including ignored files
such as local MCP client configs with API tokens.

**Build from a stable base.** The fork's `dev` follows upstream's unreleased major version. Its migrations
are ahead of every release, so a database created from it cannot move to an official image. Production
branches are an upstream release tag plus the fork's commits, for example `stable-17.8-mcp`. The workflow
runs no tests, so run `bundle exec rspec spec/requests/mcp spec/models/enterprise_token_spec.rb` on the
branch before building it.

## First deployment

1. `brew install doctl && doctl auth init`. Upload an SSH key in the control panel and find its id with
   `doctl compute ssh-key list`. Keep a second key offline and add it too; with one lost key your way in
   is the DigitalOcean recovery console.
2. `SSH_KEY_ID=<id> ./provision.sh`. It asks for confirmation, spends money, and prints each resource id as
   it is created. It writes the secrets to `~/.config/openproject-do/.env`, outside the repository, mode
   600. It refuses to run if that file exists. Do not run it with `bash -x`.
3. Point a DNS A record at the printed IP **before** the first start. Caddy requests a certificate on start,
   and repeated failures count against Let's Encrypt's rate limits.
4. Edit `~/.config/openproject-do/.env`: `OPENPROJECT_HOST__NAME`, `OPENPROJECT_IMAGE`, the admin mail
   address and the SMTP block. DigitalOcean blocks outbound ports 25, 465 and 587; the template uses 2525.
5. Run the three commands the script printed: wait for `cloud-init status --wait`, `scp` the stack to
   `/srv/openproject/`, then `./bootstrap-db.sh && ./deploy.sh`. The first start migrates an empty database
   and takes several minutes. `deploy.sh` reports the container as healthy; open the site in a browser to
   confirm DNS and the certificate.
6. Secure the accounts, in this order:
   1. Log in as `admin` with the password from `.env` and set a new one.
   2. Create a personal administrator account with a login that is not guessable. Log in with it.
   3. Lock the `admin` account. Its name is public knowledge, and anyone can block a known login for 30
      minutes at a time by failing its password 20 times.
   4. Remove `OPENPROJECT_SEED__ADMIN__USER__PASSWORD` from the server's `.env`. The seeder never resets
      an existing admin, so this is safe.
   5. Put `SECRET_KEY_BASE` in your password manager. Without it the encrypted columns are unreadable.
7. Backups: configure a remote with `rclone config`, set `RCLONE_REMOTE` in `.env`, install the cron line
   from the top of `backup.sh`, then run `./backup.sh` once by hand and check that a `db-*.dump` and an
   `assets-*.tar.gz` exist and arrived at the remote. Attachments have no other off-server copy. A remote
   outside DigitalOcean also protects against losing the whole account.
8. Do one restore drill (below) before the team depends on the system.

## MCP in production

- The endpoint is `https://<host>/mcp`. Clients authenticate with a personal API token (Basic auth, user
  `apikey`) or OAuth with the `mcp` scope. The caller's OpenProject permissions apply to every tool call.
- **Never give an AI agent an administrator's token.** An agent reads work package text, and that text can
  carry instructions. With an admin token, a planted instruction could create another administrator.
  Give agents a dedicated non-admin account. If an agent must invite people, add a global role with
  "Create users": such an account cannot set `admin` or a password.
- Switch off `create_user` under Administration, AI, Model Context Protocol unless you need it. The
  setting survives redeploys. Note that `POST /api/v3/users` remains available to the same token, which
  is why the account's permissions matter more than the switch.
- Passwords sent through `create_user` would appear in the request log. Create users as `invited`.
- The seeder creates configuration rows for new tools on every deploy, enabled.
- See `MCP_SETUP.md` in the repository root for client configuration.

## Updating

Build a new image, replace the `OPENPROJECT_IMAGE` line in the server's `.env`, run `./deploy.sh`. The
seeder migrates before web and worker start; if the pull or the migration fails, the running site stays up.
Rolling back is the previous line plus `./deploy.sh`, provided the newer migrations were backwards
compatible. Otherwise restore the database to the point before the update. Unused images older than a
week are removed.

## Restoring

**Database, point in time.** Control panel, database, Backups, "Restore to new cluster". Add the trusted
source `tag:openproject` to the new cluster, put its private URL into `.env` (database name `openproject`,
`&pool=12` appended), run `./deploy.sh`.

**Database, from a portable dump.** Restore into a fresh database, never over the live one:

```
cd /srv/openproject
docker compose stop web worker
doctl databases db create <cluster-id> openproject_restore        # from your laptop
# <restore-url> = DATABASE_URL without "&pool=12", with /openproject replaced by /openproject_restore
docker run --rm postgres:17 psql "<restore-url>" -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm' \
  -c 'CREATE EXTENSION IF NOT EXISTS btree_gist' -c 'CREATE EXTENSION IF NOT EXISTS unaccent'
docker run --rm -i postgres:17 pg_restore --no-owner --single-transaction --exit-on-error \
  -d "<restore-url>" < /var/backups/openproject/db-YYYY-MM-DD.dump                # must exit 0
# point DATABASE_URL in .env at openproject_restore (keep &pool=12), then:
./deploy.sh
```

**Attachments.**
`docker run --rm -v openproject-prod_assets:/assets -v /var/backups/openproject:/in alpine tar -xzf /in/assets-YYYY-MM-DD.tar.gz -C /assets`

**Whole server.** Restore a Droplet backup, or create a fresh Droplet with `cloud-init.yml` and
`--tag-name openproject`, then repeat step 5. The tag gives it database access and the firewall. The
Droplet holds nothing that cannot be recreated except the attachments volume.

## Getting back in

- **Login blocked after failed attempts.** The block lasts 30 minutes and a restart does not clear it:
  ```
  docker compose exec web bundle exec rails runner 'Rack::Attack::Allow2Ban.reset("login:#{ARGV[0].downcase}", maxretry: 20, findtime: 60, bantime: 1800)' <login>
  ```
- **Administrator password lost.** The policy wants 10 or more characters with lower, upper, digit and special:
  ```
  docker compose exec -e NEWPW='<new password>' web bundle exec rails runner 'u = User.find_by!(login: ARGV[0]); u.password = u.password_confirmation = ENV.fetch("NEWPW"); u.force_password_change = false; u.failed_login_count = 0; u.save!' <login>
  ```
- **SSH key lost.** Use the second key, or the recovery console in the DigitalOcean control panel. SSH
  accepts keys only; port 22 is opened before the host firewall is enabled, so first boot cannot cut it off.
- **Database unreachable from a new Droplet.** The cluster accepts Droplets tagged `openproject`. Check the
  tag, or the cluster's trusted sources in the control panel.

## Things that bite

- `OPENPROJECT_HOST__NAME` must match the public name exactly, or logins loop.
- The 1 GiB database allows 22 connections. The thread settings in `.env.example` are sized for that;
  raise them only together with the database plan.
- Never run `deploy.sh` or `docker compose up` for this stack on your own machine.
- An automatic security reboot can happen at 04:30. The stack comes back by itself.
- The size slugs, region, image, PostgreSQL version and every `doctl` flag in `provision.sh` were checked
  against a live account with doctl 1.168. Not yet exercised: the firewall rule syntax on create, whether the
  managed admin user may create the three extensions and the ICU collation, and outbound SMTP on 2525. If the first `seeder` run fails, `docker compose logs
  seeder` says why. List current slugs with `doctl compute size list` and
  `doctl databases options slugs --engine pg`.
