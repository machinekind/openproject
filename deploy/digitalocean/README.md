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
gh workflow run fork-image.yml --ref dev -f ref=dev -f tag=1.1.0
```

Setting a tag needs your login in `DEPLOY_DISPATCHERS` (see Running it by hand). Without a tag the image is
tagged with the short SHA.

**Versioning.** Tags are the fork's own semantic version, `MAJOR.MINOR.PATCH`, optionally with a prerelease
suffix such as `-rc.1`. Bump MAJOR when the upstream base moves to a new major version or a change breaks
clients or agents, MINOR for new tools or features, PATCH for fixes. `make image BUMP=minor|patch|major`
computes the next number from the highest final version among the repository's releases, its git tags and
the last local build. It resolves `REF` to a commit before dispatching, and refuses a version that already
exists as a release, a tag or the last build unless `FORCE=1`. The upstream OpenProject version is recorded
in each release's notes, not in the tag.

The run summary prints one line, `OPENPROJECT_IMAGE=ghcr.io/...:<tag>@sha256:<digest>`. Copy it whole. The
digest pins the exact image; a tag alone can be overwritten by anyone with write access to the repository.
The pipeline assumes the package `ghcr.io/machinekind/openproject` is public (the source is public too), so
the Droplet pulls without credentials. A private package needs `make ghcr-login` on the Droplet, and every
deploy fails at the pull once that token expires.

**Only build with the workflow.** A local `docker build` copies the working tree, including ignored files
such as local MCP client configs with API tokens.

**Production runs `dev`.** Production has run dev-based images since 2026-09-23. A dev build moves the schema
past every upstream release, so rolling back to an earlier base is a database restore, not a redeploy. The
seeder migrates before web starts. Every push to dev runs the fork specs and the frontend unit tests before
anything is deployed; see Continuous deployment.

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
| Allow your login to build versions and dispatch | **human** (repository admin) | `gh variable set DEPLOY_DISPATCHERS --repo machinekind/openproject --body '<your login>'` |
| Build and pin the image | agent | `make image BUMP=minor` or `make image TAG=<semver>` |
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

`make ci-setup` creates `DEPLOY_DISPATCHERS` later if it is still absent.

Put `SECRET_KEY_BASE` from the local `.env` in your password manager. Without it the encrypted columns are
unreadable. Do not run `provision.sh` with `bash -x`.

### Day to day

`make status`, `make verify`, `make logs SERVICE=web`, `make summary`. `make env-diff` names the keys that
differ between the laptop's and the server's `.env` without showing values; `make push` never overwrites a
differing server `.env`.

The server owns `OPENPROJECT_IMAGE`: every deploy, CI's included, changes it only in the server's `.env`.
`make env-diff` does not compare it and prints the image the server runs instead. `make env-push` (and
`FORCE_ENV=1 make push`) copies every other key and keeps the server's `OPENPROJECT_IMAGE` line; it refuses
while a deploy is running. `make env-pull` copies the server's file, image included.

## Continuous deployment

### What happens on a push to dev

Workflow `.github/workflows/deploy-production.yml`. Jobs, in order: frontend unit tests, fork specs, Next
version, build (`fork-image.yml`), Deploy (environment `production`), Publish release. One run at a time
per ref. A run that waited in the queue still deploys its commit, because it is an ancestor of dev; the run
for the newer commit deploys right after. Re-runs and dispatches deploy only the current tip of dev,
otherwise they stop at 'Resolve the image' before any SSH with 'dev has moved on'. A commit that is no
longer on dev (force push) is never deployed. Re-running an old run therefore never downgrades production.

Every merge by a person deploys. GitHub gives no environment secrets to a run whose actor is a bot, so a
push to dev made by a bot (for example a merge performed by Dependabot or by an app's auto-merge) fails at
Deploy for lack of `DEPLOY_SSH_KEY`. The error then says the run may have been triggered by a bot, and the
fix is a dispatch, not `make ci-setup`. Recover with a dispatch by a login in `DEPLOY_DISPATCHERS` (see Running
it by hand), not with a re-run.

The required checks 'Fork specs' and 'Units (chromium)' on the dev ruleset are what stops a red PR from
merging (see Recommended GitHub settings). Without them, only the push-to-dev run gates production.

### Versions

PATCH by default. MINOR when any pull request merged into dev since the latest release, up to the run's
commit, has the label `release:minor`, or when the workflow is run by hand with `bump=minor`. If the commits
since the latest release add migrations (`db/migrate` or `modules/*/db/migrate`), the run stops at 'Next
version' unless the bump is MINOR or MAJOR, and the step summary lists the migrations. Treat upstream syncs as
`release:minor`. MAJOR is only ever chosen by hand, and it goes through the tests and the normal build:

```
gh workflow run deploy-production.yml --repo machinekind/openproject --ref dev -f bump=major
```

The run refuses to start while the repository has no final release. It also refuses when the latest release's
commit is not an ancestor of the run's commit. That happens to a stale run, and to a release built by hand
from a commit that is not on dev; merge that commit into dev with a merge commit (not squash or rebase).

### What the server allows

The deploy key is one line in `/root/.ssh/authorized_keys`:

```
restrict,command="/srv/openproject/ops/remote/ci-deploy.sh" ssh-ed25519 <key> github-actions-deploy
```

The key can do three things: `deploy <ghcr.io/machinekind/openproject:<tag>@sha256:<digest>>`, `status` and
`version`. No shell, no file copy, no port forwarding. CI never copies files to the server. Before each
deploy, the runner compares the hashes of `deploy.sh`, `docker-compose.yml`, `Caddyfile` and
`ops/remote/ci-deploy.sh` on the server with the commit. When they differ, it stops and asks for `make push`
(agent) followed by re-running the job.

### What deploy.sh does

- Takes a lock (`another deploy is running`).
- Pulls before `.env` changes, so a failed pull changes nothing. An image that is already on the server, by
  digest, is not pulled, so a rollback works while GHCR or Docker Hub is down.
- Dumps the database to `/var/backups/openproject/db-predeploy-<tag>-<UTC time>-<digest prefix>.dump`, one
  file per attempt. It takes about a minute.
- Reads a fingerprint of the schema: the `schema_migrations` versions plus the columns and indexes of schema
  `public`.
- Records the image `.env` named before this attempt in `.deploy/previous-image` (the target of
  `make rollback`) when the image changes. A failed image never becomes the previous one.
- Runs the seeder migration, then waits for health for up to 10 minutes.

After every healthy deploy, deploy.sh records the fingerprint and the running image in
`.deploy/healthy-schema`.

On failure, `.env` goes back to the previous image:

- If the current fingerprint equals the recorded one for that image, deploy.sh starts it again, waits for
  health and prints `rolled back automatically to <image>: no migration had run`. The deploy still counts as
  failed.
- Otherwise (schema changed, fingerprint unreadable, no record yet, or a record for another image) nothing
  is restarted. `.deploy/last-dump` gets this attempt's dump path unless it already exists (`make status`
  shows it), and deploy.sh prints the two choices: roll forward with a fixed image, or restore that dump and
  then `make rollback`.

A failure that changed the schema leaves the record stale, so later failures restart nothing until a healthy
deploy, or a restore of that dump, brings the schema back. The first deploy after this kit version has no
record yet and never restarts automatically.

After a healthy deploy, images other than the current and the previous one are removed, and only the 3 newest
pre-deploy dumps are kept; a failed attempt removes nothing. The nightly backup cleanup also removes dumps
older than 7 days. The last line is `running: <image>`, and the runner checks it. Afterwards the runner runs
the checks of `make verify` from outside, and only then publishes the release.

### One-time setup

| Step | Who | Command |
|---|---|---|
| Host key known | **human** | `ssh root@<droplet ip> true`; accept only if the fingerprint matches `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` run in the Droplet's Recovery Console (control panel, Access) |
| Make the package public: package settings page of `ghcr.io/machinekind/openproject`, Change visibility, Public. Then drop the Droplet's token | **human**, agent | `make ghcr-logout` |
| Put the current kit on the server | agent | `make push` from an up-to-date dev |
| Create the GitHub side and install the key | **human** | `make ci-setup` |
| Create the label | **human** | `gh label create release:minor --repo machinekind/openproject --color 0E8A16 --description "Deploy as a MINOR release; required when a merge adds migrations"` |
| Baseline release; the human decides the number | **human** | `make release IMAGE=<running image from make status> TAG=<baseline, e.g. 1.0.0> SHA=<its commit>`; SHA must be a commit on dev |
| First run | human or agent | `gh workflow run deploy-production.yml --repo machinekind/openproject --ref dev` (add `-f bump=minor` if migrations landed since the baseline) |

`make ci-setup` first prints the `ssh-keygen -l` fingerprints of the host key lines it will pin and asks you
to confirm that they match the Recovery Console. It reads the environment `production` first and leaves it
alone when it already uses custom deployment branch policies. Otherwise it switches it to custom policies
and keeps reviewers, wait timer, self-review and admin bypass. It removes every deployment policy other than
branch dev, then verifies the mode and that branch dev is the only policy. It sets the variables
`DEPLOY_HOST_IP`, `DEPLOY_HOST_NAME` and `DEPLOY_SSH_HOST_KEY` (taken from the operator's known_hosts, not
from a scan), and sets the secret `DEPLOY_SSH_KEY` last. Any GitHub error other than 'not found' stops it
at that step; rerunning is safe. It creates `DEPLOY_PAUSED=false` and `DEPLOY_DISPATCHERS=<your login>` only when
they are absent, and warns when `DEPLOY_DISPATCHERS` is malformed. The private key lives only in a temporary
directory that is deleted. Rerunning `make ci-setup` rotates the key.

### Running it by hand

`gh workflow run deploy-production.yml` works only for the logins in the repository variable
`DEPLOY_DISPATCHERS`: GitHub logins separated by commas, without spaces, compared case-insensitively.
Repository admins edit it. Missing, empty or malformed means no one may dispatch. A refused dispatch shows a
failed 'Check the dispatcher' job. When the variable is well-formed, Deploy is then skipped without entering
the production environment. With a malformed value Deploy may start, but it stops at 'Resolve the image'
before any SSH: the check in `pipeline.sh` is the authoritative one. The same list gates version tags on
`fork-image.yml` dispatches, so `make image` needs your login in it. Push runs are unaffected. A repository
admin adds a login with
`gh variable set DEPLOY_DISPATCHERS --repo machinekind/openproject --body '<login>,<login>'`.

GHCR tags can be overwritten by anyone with write access, so only the digest identifies an image. The
`image` input deploys a digest without tests, so keep it for planned redeploys of an image from a release's
notes.

### Pausing

- `make ci-pause` / `make ci-resume` (human): set the repository variable `DEPLOY_PAUSED`. Tests and build
  still run; the Deploy job is skipped, dispatches included.
- `make deploy-hold` / `make deploy-unhold` (agent): create or remove `/srv/openproject/DEPLOY_PAUSED` on the
  server. The server refuses every CI deploy, dispatches included, even if the variable says otherwise.

Neither blocks `make deploy` or `make rollback` from a laptop. A manual `make deploy` is replaced by the next
CI run unless deploys are held or paused until the change is on dev.

Pause before a risky upstream sync and resume after reading the migration list.

### Rolling back

In an incident:

1. `make -C deploy/digitalocean deploy-hold`, so no CI run deploys over you.
2. `make status` shows the running image, the previous image and, after a failed deploy that may have
   migrated, the restore point in `.deploy/last-dump`.
3. `make -C deploy/digitalocean rollback` from the laptop. It deploys `/srv/openproject/.deploy/previous-image`,
   which is the image `.env` named before the last switch, also when that switch failed. It bypasses the
   GitHub queue and both pauses, and it keeps running on the server if the SSH connection drops (its output
   is also appended to `/srv/openproject/.deploy/deploy.log`). Running it twice switches back again.
4. `make deploy-unhold` once dev holds the fix.

Rolling back is valid only when the newer migrations are backwards compatible; otherwise see Restoring.

The `image` dispatch is for planned redeploys by a login in `DEPLOY_DISPATCHERS`, and needs both pauses
lifted. Each release's notes show its image:

```
gh workflow run deploy-production.yml --repo machinekind/openproject --ref dev -f image=<image>
```

### Revoking

`make ci-revoke` (agent) removes the key from the server at once. A person then runs
`gh secret delete DEPLOY_SSH_KEY --env production --repo machinekind/openproject`.

### Public logs

The repository is public, so Actions logs are too. Server output passes through the redact filter. Never add
`set -x` to the kit and never print `docker compose logs` in a workflow.

### Testing the kit

`make test` (agent) runs shellcheck and the stub tests in `test/` in Docker, with the Ubuntu 24.04 tools the
server has; they do not run with macOS tools. The workflow 'Workflow and deploy kit checks' runs the same
target on every pull request that touches `deploy/digitalocean/`.

### Recommended GitHub settings

A person runs these. The pipeline works without them.

Require the checks 'Fork specs' and 'Units (chromium)' on the dev ruleset:

```
gh api repos/machinekind/openproject/rulesets/23618378 \
  | jq '{name, target, enforcement, conditions, bypass_actors, rules: (.rules + [{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"do_not_enforce_on_create":false,"required_status_checks":[{"context":"Fork specs","integration_id":15368},{"context":"Units (chromium)","integration_id":15368}]}}])}' \
  | gh api -X PUT repos/machinekind/openproject/rulesets/23618378 --input -
```

Also consider 1 required approval with `require_last_push_approval` once there are two reviewers, and fewer
always-bypass actors. Only bypass actors can update dev today.

Restrict Actions to pinned, selected actions:

```
gh api -X PUT repos/machinekind/openproject/actions/permissions -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
gh api -X PUT repos/machinekind/openproject/actions/permissions/selected-actions -F github_owned_allowed=true -F verified_allowed=true \
  -f 'patterns_allowed[]=opf/action-erblint@*' -f 'patterns_allowed[]=reviewdog/*' -f 'patterns_allowed[]=ruby/setup-ruby@*' -f 'patterns_allowed[]=docker/*'
```

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

GitHub Actions deploys every merge to dev (see Continuous deployment). The laptop path still works and uses the
same `deploy.sh`: `make image BUMP=minor|patch|major` (from dev, the default `REF`), `make deploy IMAGE=<the
printed image>`, `make verify`. `make status` shows the running image. The next CI run replaces a manual
deploy, so run `make deploy-hold` first unless the change is already on dev. `make deploy` keeps running on
the server if the SSH connection drops and appends its output to `/srv/openproject/.deploy/deploy.log`.

Failures:

- A failed pull or pre-deploy dump changes nothing.
- A failure before any migration ran (the schema is still the one the previous image last ran healthy on) starts the previous image
  again automatically and still reports the deploy as failed.
- A failure after a migration ran leaves web and worker stopped (failed migration, Caddy answers 502) or the
  new containers running (health timeout), with `.env` back on the previous image and the dump to restore
  in `.deploy/last-dump`.

In the last case a person decides between rolling forward with a fixed image, `make rollback` (only with
backwards compatible migrations) and restoring `.deploy/last-dump` (see Restoring). Even a successful deploy
has a few minutes of downtime: migrate, seed, then web boot.

After a successful deploy, `make deploy` reads the image the server is running and publishes a GitHub release
named after its tag, with notes listing the PRs merged since the previous final release below it. A failed
release never fails the deploy. An image not built on this machine gets no release unless you run
`make release IMAGE=... SHA=<commit>`. That also backfills a missed version: a final version older than the
newest release is published without being marked latest, and a prerelease tag is published as a prerelease.
In CI the release is published only after verify passes, and a dispatch with `image` publishes none.

## Restoring

**Pause deploys first:** `make deploy-hold`.

**Database, from the pre-deploy dump.** After a failed deploy that may have migrated, `make status` shows the
restore point, the path in `/srv/openproject/.deploy/last-dump`. It is the dump taken just before the first
failed attempt, so later retries do not replace it. Restore that file with the portable-dump procedure below.
Dump names carry the tag being deployed and the UTC time, if you need another one.

**Database, point in time.** Control panel, database, Backups, "Restore to new cluster". Add the trusted
source `tag:openproject` to the new cluster, put its private URL into the local `.env` (database name
`openproject`, `&pool=12` appended), check with `make env-diff` that `DATABASE_URL` is the only differing
key, run `make env-push` (it keeps the server's `OPENPROJECT_IMAGE`), then `make rollback` or
`make deploy IMAGE=<image that matches that point in time>`.

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
# point DATABASE_URL in .env at openproject_restore (keep &pool=12)
```

Then run `make rollback` from the laptop, or `make deploy IMAGE=<image that matches the dump>`. Never a bare
`./deploy.sh` or `make deploy`: after a deploy that went healthy, `.env` still names the new image, and its
seeder would apply the same migrations to the restored database again.

**Attachments.**
`docker run --rm -v openproject-prod_assets:/assets -v /var/backups/openproject:/in alpine tar -xzf /in/assets-YYYY-MM-DD.tar.gz -C /assets`

**Whole server.** Run `make ci-pause` first: a Droplet backup taken before `make deploy-hold` comes back
without the hold, and a fresh Droplet has none. Restore a Droplet backup, or create a fresh Droplet with
`cloud-init.yml` and `--tag-name openproject`; the tag gives it database access and the firewall. The
Droplet holds nothing that cannot be recreated except the attachments volume. Then:

1. `make adopt` (a fresh Droplet has a new IP) and `make push`.
2. Pin the new host key as in One-time setup, then rerun `make ci-setup`; it publishes the new IP and host
   key to GitHub and installs the deploy key.
3. `make deploy-hold` again if you still need it, then `make ci-resume`.

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
