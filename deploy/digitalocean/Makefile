# Operations for the DigitalOcean deployment. Run `make help`.
#
# [agent] targets are safe for an AI agent: they never print a secret and spend no money.
# [human] targets spend money, prompt for a secret or print one. They refuse to run without a terminal.
# State (Droplet IP, database id, host) lives in ~/.config/openproject-do/state, secrets in .env next to it.

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
OPS := ./ops
export

help: ## [agent] List all targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'
	@echo; echo "  New deployment:  preflight, image, provision*, configure, dns-wait, up, create-admin*, harden, backup-install, roles"
	@echo "  Update:          image BUMP=..., deploy IMAGE=..., verify          (* = a person must run it)"

# --- set up -------------------------------------------------------------------------------------
preflight: ## [agent] Check tools, logins and the DigitalOcean names provision.sh uses
	@$(OPS)/infra.sh preflight
image: ## [agent] Build the fork image and pin it by digest. BUMP=minor|patch|major or TAG=1.2.0 [REF=dev]. Refuses an existing version unless FORCE=1
	@$(OPS)/infra.sh image
provision: ## [human] Create Droplet, database and firewall. Spends money. SSH_KEY_ID=...
	@bash -c '. $(OPS)/common.sh; require_tty provision' && ./provision.sh
adopt: ## [agent] Rebuild the state file for a deployment that already exists
	@$(OPS)/infra.sh adopt
configure: ## [agent] Set host name and admin mail. HOST=op.example.org [ADMIN_MAIL=..] [IMAGE=..]
	@$(OPS)/infra.sh configure
dns-wait: ## [agent] Wait until the host name resolves to the Droplet
	@$(OPS)/infra.sh dns-wait
up: ## [agent] First start: push files, create extensions, deploy, verify
	@$(OPS)/stack.sh up

# --- run ----------------------------------------------------------------------------------------
push: ## [agent] Copy the stack files to the server. Never overwrites a differing .env unless FORCE_ENV=1
	@$(OPS)/stack.sh push
deploy: ## [agent] Pull and restart, then publish a release for the running image. With IMAGE=... switch to that image first
	@$(OPS)/stack.sh deploy
release: ## [agent] Publish a GitHub release for an image (default: the pinned one); backfills older versions without marking them latest, with notes generated from merged PRs. [TAG=] [SHA=] [PREV=] [REF=] [UPSTREAM=] [IMAGE=] [NOTES=] [DEPLOYED=]
	@$(OPS)/infra.sh release
verify: ## [agent] Check the live site from the outside: TLS, redirects, closed endpoints, open ports
	@$(OPS)/stack.sh verify
status: ## [agent] Containers, memory, disk, last backup
	@$(OPS)/stack.sh status
summary: ## [agent] Users, projects, settings, as seen by the application (slow: boots Rails)
	@$(OPS)/stack.sh summary
logs: ## [agent] Redacted container logs. [SERVICE=web] [TAIL=60]
	@$(OPS)/stack.sh logs
env-diff: ## [agent] Names of .env keys that differ between laptop and server. Values are never shown
	@$(OPS)/stack.sh env-diff
env-push: ## [agent] Make the local .env win
	@$(OPS)/stack.sh env-push
env-pull: ## [agent] Make the server's .env win (keeps a local .env.bak)
	@$(OPS)/stack.sh env-pull

# --- accounts -----------------------------------------------------------------------------------
admin-password: ## [human] Show the seeded admin's initial password
	@$(OPS)/accounts.sh admin-password
create-admin: ## [human] Create a personal administrator. LOGIN= FIRST= LAST= MAIL=
	@$(OPS)/accounts.sh create-admin
reset-password: ## [human] Set a new password for any account. LOGIN=
	@$(OPS)/accounts.sh reset-password
add-users: ## [human] Create users from a CSV and print temporary passwords. FILE=users.csv
	@$(OPS)/accounts.sh add-users
unban: ## [agent] Clear a login block after failed attempts. LOGIN=
	@$(OPS)/accounts.sh unban
harden: ## [agent] Lock the seeded admin once another administrator exists; remove the seed password
	@$(OPS)/maintain.sh harden
roles: ## [agent] Create the global team-lead role and make project creators Project admin. [ROLE=Moderator]
	@$(OPS)/maintain.sh roles

# --- backups, mail, registry, MCP ---------------------------------------------------------------
backup-now: ## [agent] Run a backup and list the files
	@$(OPS)/maintain.sh backup-now
backup-install: ## [agent] Install the nightly backup
	@$(OPS)/maintain.sh backup-install
backup-remote: ## [human] Configure the off-server rclone remote (interactive)
	@$(OPS)/maintain.sh backup-remote
backup-remote-set: ## [agent] Use an rclone remote for backups. REMOTE=offsite-crypt:
	@$(OPS)/maintain.sh backup-remote-set
restore-drill: ## [agent] Restore the newest dump into a scratch database, compare counts, drop it
	@$(OPS)/maintain.sh restore-drill
smtp-test: ## [agent] Can the server reach the mail host? SMTP_HOST= [SMTP_PORT=2525]
	@$(OPS)/maintain.sh smtp-test
smtp-configure: ## [human] Store mail settings. SMTP_HOST= SMTP_USER= MAIL_FROM= [SMTP_PORT=2525]
	@$(OPS)/maintain.sh smtp-configure
ghcr-login: ## [human] Log the server in to GHCR for a private image. GH_USER=
	@$(OPS)/maintain.sh ghcr-login
ghcr-logout: ## [agent] Remove the GHCR credential from the server
	@$(OPS)/maintain.sh ghcr-logout
mcp-register: ## [human] Register this instance's MCP endpoint in Claude Code. [MCP_NAME=openproject-prod]
	@$(OPS)/maintain.sh mcp-register

.PHONY: help preflight image provision adopt configure dns-wait up push deploy release verify status summary logs env-diff env-push env-pull admin-password create-admin reset-password add-users unban harden roles backup-now backup-install backup-remote backup-remote-set restore-drill smtp-test smtp-configure ghcr-login ghcr-logout mcp-register
