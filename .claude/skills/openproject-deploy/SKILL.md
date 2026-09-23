---
name: openproject-deploy
description: Deploy, update, inspect and maintain the DigitalOcean production instance of this OpenProject fork through the Makefile in deploy/digitalocean. Use whenever the user asks to deploy, redeploy, update or roll back production, build or pin the production image, check whether the site is up or healthy, look at production logs or status, run or verify backups, do a restore drill, harden accounts, set up roles, configure mail, or stand up a new instance, even if they only say "ship it", "is prod ok" or "set it up again".
---

# Operating the DigitalOcean deployment

Everything goes through `make -C deploy/digitalocean <target>`. Run `make -C deploy/digitalocean help` for the list.
State (Droplet IP, database id, host name) lives in `~/.config/openproject-do/state`. Secrets live in
`~/.config/openproject-do/.env` and in `/srv/openproject/.env` on the server.

## The one rule

You never see a secret. That is what makes it safe for you to operate production.

- Run only targets tagged `[agent]`. They print no secrets and spend no money.
- Targets tagged `[human]` spend money, prompt for a secret or print one. They refuse to run without a
  terminal, so you cannot run them. Hand them to the user as one exact command and wait.
- Never `cat`, `grep`, `head` or otherwise read either `.env` file, and never ask the user to paste one.
  `make env-diff` tells you which keys differ without showing values.
- Never SSH to the server by hand to work around a target. If a target is missing, add it to the kit.
- Do not run `provision.sh`, `deploy.sh` or `docker compose` for this stack on the user's machine.

## Start by looking

```
make -C deploy/digitalocean status     # containers, memory, disk, last backup, running image
make -C deploy/digitalocean verify     # 15 checks from the outside; exits non-zero on any failure
```

If the state file is missing, `make adopt` rebuilds it from the DigitalOcean account.

## Update production

1. `make image BUMP=minor|patch|major [REF=dev]` resolves `REF` to a commit, computes the next version from
   the highest final version among the releases, git tags and the last local build, builds in GitHub
   Actions, waits about 7 minutes, and pins the image **by digest** locally. Choose the bump from the PRs
   merged since that release: major if the upstream base changed major version or a change breaks clients
   or agents, minor if any adds a tool or feature, otherwise patch. `TAG=1.2.0` sets the version by hand
   instead; it must be semver, `MAJOR.MINOR.PATCH[-prerelease]`. A version that already exists as a
   release, a tag or the last build is refused; `FORCE=1` overwrites its published image tag, so ask the
   user before passing it. Production has run
   dev-based images since 2026-09-23: the schema is past every upstream release, so rolling back to an
   earlier base is a database restore, not a redeploy. The workflow runs no tests, so run
   `bundle exec rspec spec/requests/mcp spec/models/enterprise_token_spec.rb` on that branch first.
2. `make deploy IMAGE=<the image line from step 1>` switches the server to it. The seeder migrates before
   web and worker start. If the pull or a migration fails, the running site stays up.
3. `make verify`, then `make status`.
4. Rolling back is `make deploy IMAGE=<previous image>`, provided the newer migrations were backwards
   compatible. `make status` shows the image that is running now; note it before you deploy.
5. After a successful deploy, `make deploy` publishes a GitHub release for the image the server is running,
   named after its tag, with notes listing the PRs merged since the previous final release below it. A
   failed release never fails the deploy. An image not built on this machine, or a missed version, gets a
   release with `make release IMAGE=<image> SHA=<commit>`: an older final version is not marked latest, a
   prerelease tag is published as a prerelease.

If the pull fails with `unauthorized`, the GHCR package is private and the server is not logged in. The user
either makes the package public or runs `make ghcr-login GH_USER=<login>`.

## A new instance

| Step | Who | Command |
|---|---|---|
| Check tools, logins and names | agent | `make preflight` |
| Create Droplet, database, firewall | **human** | `make provision SSH_KEY_ID=<id>` |
| Host name and admin mail | agent | `make configure HOST=<host> ADMIN_MAIL=<mail>`, then tell the user which DNS A record to create |
| Build and pin the image | agent | `make image BUMP=minor` (or `TAG=<semver>`) |
| Wait for DNS | agent | `make dns-wait` |
| Push files, create extensions, start, verify | agent | `make up` (the first start migrates an empty database and takes 5 to 10 minutes) |
| First login | **human** | `make admin-password`, then log in as `admin` and set a new password |
| Personal administrator | **human** | `make create-admin LOGIN=<not guessable> FIRST= LAST= MAIL=` |
| Lock `admin`, remove the seed password | agent | `make harden` (refuses while `admin` is the only administrator) |
| Nightly backup | agent | `make backup-install`, then `make backup-now` to see both files |
| Team-lead role, creator role | agent | `make roles` |
| Off-server backups | **human**, then agent | `make backup-remote`, then `make backup-remote-set REMOTE=<remote>:` |
| Mail | agent, then **human** | `make smtp-test SMTP_HOST=<host>`, then `make smtp-configure ...`, then `make deploy` |
| Prove a restore works | agent | `make restore-drill` |
| Connect an agent to it | **human** | `make mcp-register` |

## Things that have gone wrong before

- **A wrong DNS answer on the user's machine.** macOS caches "no such host". `verify` and `dns-wait` bypass
  the local resolver, so trust them over a browser error right after a DNS change.
- **The bare IP shows nothing.** Caddy serves only the host name, over HTTPS.
- **Nothing listens until the first migration finishes.** Web waits for the seeder, and the proxy waits for
  web. Closed ports for several minutes after the first `make up` are normal.
- **Rails commands are slow.** `summary`, `harden`, `roles`, `unban` and the account targets boot the
  application first, which takes 30 to 90 seconds and prints nothing meanwhile.
- **`push` does not overwrite a differing server `.env`.** Decide with `env-diff`, then `env-push` or
  `env-pull`.
- **DigitalOcean blocks outbound ports 25, 465 and 587.** Use a mail provider that accepts 2525.
- **Password policy:** 10 or more characters with lowercase, uppercase, digit and special character.

Read `deploy/digitalocean/README.md` for sizing, restore procedures and recovery commands.
