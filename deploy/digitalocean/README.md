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

## Operating it: `make`

Everything is a `make` target in this directory. `make help` lists them. State (Droplet IP, database id, host
name) is kept in `~/.config/openproject-do/state` and the secrets in `.env` next to it, both outside the
repository.

Targets are tagged **[agent]** or **[human]**. Agent targets never print a secret and spend no money, so an
AI agent can run them; `.claude/skills/openproject-deploy` tells it how. Human targets spend money, prompt
for a secret or print one, and refuse to run without a terminal.

### First deployment

| Step | Who | Command |
|---|---|---|
| Install and log in | human | `brew install doctl && doctl auth init`, upload an SSH key, keep a second one offline |
| Check tools, logins, names | agent | `make preflight` |
| Create Droplet, database, firewall | **human** | `make provision SSH_KEY_ID=<id>` |
| Host name and admin mail | agent | `make configure HOST=<host> ADMIN_MAIL=<mail>`, then create the DNS A record it names |
| Build and pin the image | agent | `make image TAG=<tag>` |
| Wait for DNS | agent | `make dns-wait`. Caddy requests a certificate on start, and failures count against rate limits |
| Start | agent | `make up`. The first start migrates an empty database and takes 5 to 10 minutes |
| First login | **human** | `make admin-password`, log in as `admin`, set a new password |
| Personal administrator | **human** | `make create-admin LOGIN=<not guessable> FIRST= LAST= MAIL=` |
| Lock `admin`, drop the seed password | agent | `make harden`. Anyone can block a known login for 30 minutes by failing its password |
| Nightly backup | agent | `make backup-install`, then `make backup-now` |
| Team-lead role | agent | `make roles` |
| Off-server backups | **human**, agent | `make backup-remote`, then `make backup-remote-set REMOTE=<remote>:`. Attachments have no other off-server copy |
| Mail | agent, **human** | `make smtp-test SMTP_HOST=<host>`, `make smtp-configure ...`, `make deploy` |
| Restore drill | agent | `make restore-drill` |

Put `SECRET_KEY_BASE` from the local `.env` in your password manager. Without it the encrypted columns are
unreadable. Do not run `provision.sh` with `bash -x`.

### Day to day

`make status`, `make verify`, `make logs SERVICE=web`, `make summary`. `make env-diff` names the keys that
differ between the laptop's and the server's `.env` without showing values; `make push` never overwrites a
differing server `.env`.

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

`make image TAG=<new tag>`, then `make deploy IMAGE=<the printed image>`, then `make verify`. The seeder
migrates before web and worker start; if the pull or the migration fails, the running site stays up. Rolling
back is `make deploy IMAGE=<previous image>`, provided the newer migrations were backwards compatible.
Otherwise restore the database to the point before the update. `make status` shows the running image.
Unused images older than a week are removed. Every `make deploy` publishes a GitHub release named after the image
tag, with notes listing the PRs merged since the previous release; a rollback or an image not built on this
machine gets no release unless you run `make release TAG=... SHA=...`.

## Restoring

**Database, point in time.** Control panel, database, Backups, "Restore to new cluster". Add the trusted
source `tag:openproject` to the new cluster, put its private URL into `.env` (database name `openproject`,
`&pool=12` appended), run `./deploy.sh`.

**Database, from a portable dump.** `make restore-drill` proves the newest dump restores, using a scratch
database that it drops afterwards. For a real restore, do the same by hand into a fresh database, never over
the live one:

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

- **Login blocked after failed attempts.** `make unban LOGIN=<login>`. The block lasts 30 minutes and a
  restart does not clear it.
- **Password lost, any account.** `make reset-password LOGIN=<login>`. The policy wants 10 or more characters
  with lowercase, uppercase, digit and special character.
- **SSH key lost.** Use the second key, or the recovery console in the DigitalOcean control panel. SSH
  accepts keys only; port 22 is opened before the host firewall is enabled, so first boot cannot cut it off.
- **Database unreachable from a new Droplet.** The cluster accepts Droplets tagged `openproject`. Check the
  tag, or the cluster's trusted sources in the control panel.
- **State file lost.** `make adopt` rebuilds it from the DigitalOcean account.

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
