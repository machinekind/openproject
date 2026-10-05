---
name: openproject-deploy
description: Deploy, update, inspect and maintain the DigitalOcean production instance of this OpenProject fork through the Makefile in deploy/digitalocean. Use whenever the user asks to deploy, redeploy, update or roll back production, build or pin the production image, check whether the site is up or healthy, look at production logs or status, run or verify backups, check, pause or roll back the GitHub Actions deploy pipeline, do a restore drill, harden accounts, set up roles, configure mail, or stand up a new instance, even if they only say "ship it", "is prod ok" or "set it up again".
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

Production deploys itself on every merge to dev through `.github/workflows/deploy-production.yml` (tests,
version, build, deploy, verify, release). Look first:
`gh run list --workflow deploy-production.yml --repo machinekind/openproject --limit 5`, and
`gh run view <id> --repo machinekind/openproject --log-failed` for failures. A fix normally ships by merging
it to dev. The numbered steps below are the manual path for new instances and for a hotfix that cannot wait;
the next CI run deploys dev over a manual deploy, so run `make deploy-hold` before a manual hotfix deploy,
tell the user, and run `make deploy-unhold` only when the fix is on dev and the user agrees.

1. `make image BUMP=minor|patch|major [REF=dev]` resolves `REF` to a commit (keep `REF=dev`: a release built
   from a commit that is not on dev stops every CI run at 'Next version' until that commit is merged into dev), computes the next version from
   the highest final version among the releases, git tags and the last local build, builds in GitHub
   Actions, waits about 7 minutes, and pins the image **by digest** locally. Choose the bump from the PRs
   merged since that release: major if the upstream base changed major version or a change breaks clients
   or agents, minor if any adds a tool or feature, otherwise patch. `TAG=1.2.0` sets the version by hand
   instead; it must be semver, `MAJOR.MINOR.PATCH[-prerelease]`. A version that already exists as a
   release, a tag or the last build is refused; `FORCE=1` overwrites its published image tag, so ask the
   user before passing it. The build stops at 'Validate inputs' with '... may not set a version tag' when
   the user's login is not in `DEPLOY_DISPATCHERS`: tell the user; a repository admin adds it, never change
   it yourself. Production has run
   dev-based images since 2026-09-23: the schema is past every upstream release, so rolling back to an
   earlier base is a database restore, not a redeploy.
2. `make deploy IMAGE=<the image line from step 1>` switches the server to it. The seeder migrates before
   web and worker start. A failed pull changes nothing. A failed deploy restarts the previous image by itself
   only when the schema is still the one that image last ran healthy on; the output then says 'rolled back
   automatically'. This never happens on the first deploy after a kit update. Otherwise the site stays down
   or unhealthy and the restore point is printed (also in `make status`); tell the user, because rolling
   back is only safe with backwards compatible migrations. The deploy keeps running on the server if your command times out; check with
   `make status`.
3. `make verify`, then `make status`.
4. Rolling back is `make rollback`, provided the newer migrations were backwards compatible. It deploys the
   previous image that `make status` shows: the image `.env` named before the last switch, also when that
   switch failed.
5. After a successful deploy, `make deploy` publishes a GitHub release for the image the server is running,
   named after its tag, with notes listing the PRs merged since the previous final release below it. A
   failed release never fails the deploy. An image not built on this machine, or a missed version, gets a
   release with `make release IMAGE=<image> SHA=<commit>`: an older final version is not marked latest, a
   prerelease tag is published as a prerelease.

If the pull fails with `unauthorized`, the GHCR package is private and the server is not logged in. The user
either makes the package public or runs `make ghcr-login GH_USER=<login>`.

## Continuous deployment

| Situation | What you do |
|---|---|
| 'Next version' fails with new migrations | Tell the user. They add the label `release:minor` to any PR merged since the latest release. If the run's commit is still the tip of dev, re-run with `gh run rerun <id> --repo machinekind/openproject --failed`; otherwise wait for the newest run or, once they agree, run `gh workflow run deploy-production.yml --repo machinekind/openproject --ref dev -f bump=minor`. |
| 'is not an ancestor' at 'Next version', or 'dev has moved on' at Deploy | The run is stale. 'dev has moved on' comes from a re-run or a dispatch whose commit is no longer the tip of dev. Do not re-run; the run for the newest commit deploys. A first-attempt run that waited in the queue deploys its older commit, and the newer run follows: that is normal. 'is not on dev any more' means dev was rewritten; tell the user. If the latest release was built from a commit that is not on dev, tell the user to merge that commit into dev with a merge commit. |
| '... may not run this workflow by hand', '... may not set a version tag', or 'DEPLOY_DISPATCHERS is missing, empty or not GitHub logins separated by commas' | The user's login is not in the repository variable `DEPLOY_DISPATCHERS`, or its value is malformed. It takes logins separated by commas without spaces. A repository admin sets it; never change it yourself. A refused dispatch shows a failed 'Check the dispatcher' job; with a malformed value the Deploy job may also start and fail at 'Resolve the image', which is expected. |
| A MAJOR release | Only when the user asks: `gh workflow run deploy-production.yml --repo machinekind/openproject --ref dev -f bump=major`. |
| Deploy error 'DEPLOY_SSH_KEY: is empty ... triggered by a bot' after a bot's push | Runs started by a bot get no environment secrets. Dispatch as a `DEPLOY_DISPATCHERS` login: `gh workflow run deploy-production.yml --repo machinekind/openproject --ref dev` once the user agrees. Do not re-run the run and do not re-run `ci-setup`; neither helps. |
| 'no final release yet' | The user chooses a baseline version; then `make release IMAGE=... TAG=... SHA=...`. |
| 'deploy kit differs' | `make push`, then re-run the failed jobs if the run's commit is still the tip of dev. |
| 'refused: deploys are paused on this server' | Someone ran deploy-hold. Run `make deploy-unhold` only when the user says so. |
| Pull fails with 'unauthorized' | The package is private and the server has no valid login; the user makes it public or runs `make ghcr-login`. |
| Site broken after a deploy | `make deploy-hold`, then `make status` and `make logs SERVICE=seeder`. If deploy.sh printed 'rolled back automatically', production already runs the previous image. Otherwise offer `make rollback` (only safe with backwards compatible migrations) or a restore of the dump `make status` names; never a bare `make deploy`. Use `make rollback` from the laptop, not the GitHub `image` dispatch: the hold blocks every CI deploy. |

Agent targets: `deploy-hold`, `deploy-unhold`, `rollback`, `ci-revoke`, `push`, `test`. Human targets:
`ci-setup`, `ci-pause`, `ci-resume` (hand over the exact command). Never read, request or print
`DEPLOY_SSH_KEY`; never change GitHub environments, secrets, variables, rulesets or package visibility
yourself. After you change anything in `deploy/digitalocean`, run `make test`.

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
  `env-pull`. The server owns `OPENPROJECT_IMAGE`: `env-diff` ignores it and `env-push` keeps the server's
  value.
- **DigitalOcean blocks outbound ports 25, 465 and 587.** Use a mail provider that accepts 2525.
- **Password policy:** 10 or more characters with lowercase, uppercase, digit and special character.

Read `deploy/digitalocean/README.md` for sizing, restore procedures and recovery commands.
