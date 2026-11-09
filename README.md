# Machinekind OpenProject

Machinekind runs this fork of OpenProject at <https://projects.machinekind.ai>. This guide connects your AI agent
to it through MCP (Model Context Protocol).

## 1. Create an API token

1. Sign in at <https://projects.machinekind.ai>.
2. Open your avatar menu, choose **Account settings**, then **Access tokens**. The direct link is
   <https://projects.machinekind.ai/my/access_tokens>.
3. In the **API** section, click **+ API token**, give it a name and create it.
4. Copy the token. It starts with `opapi-`, and OpenProject shows it only once.

The agent acts as you. It can change anything you can change, and its changes apply immediately. Keep the token
private, like a password.

## 2. Connect your client

Each client below registers the server as `openproject-prod`.

### Claude Code (CLI and desktop app)

The Code tab in the Claude desktop app uses the same MCP settings as the CLI, so one command sets up both. Run it in
a terminal. It asks for the token without showing it, which keeps the token out of your shell history.

```bash
printf "OpenProject token: "; read -rs T; echo
claude mcp add --transport http --scope user openproject-prod https://projects.machinekind.ai/mcp \
  --header "Authorization: Bearer $T"
unset T
```

Start a new session in the CLI or the app. `claude mcp list` should show `openproject-prod` as connected.

If the `claude` command is missing, install it first:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

### Codex (CLI and desktop app)

The Codex CLI and desktop app share `~/.codex/config.toml`. Run this in a terminal to add the server to that file:

```bash
printf "OpenProject token: "; read -rs T; echo
mkdir -p ~/.codex
cat >> ~/.codex/config.toml <<EOF

[mcp_servers.openproject-prod]
url = "https://projects.machinekind.ai/mcp"
http_headers = { Authorization = "Bearer $T" }
EOF
chmod 600 ~/.codex/config.toml
unset T
```

Restart the Codex app or CLI. `codex mcp list` should list `openproject-prod`. In the app, type `/mcp` in the
composer to see it.

### Antigravity

Antigravity reads MCP servers from `mcp_config.json`. Open the file:

- **App:** click **Customizations**, then **Installed**. In **MCP Servers**, click **Copy Config File Path** and open
  that file.
- **IDE:** click **…** at the top of the agent panel, then **MCP Servers**, **Manage MCP Servers** and
  **View raw config**.
- **CLI:** edit `~/.gemini/config/mcp_config.json`.

Add the `openproject-prod` entry under `mcpServers`, and replace `YOUR_TOKEN` with your token:

```json
{
  "mcpServers": {
    "openproject-prod": {
      "serverUrl": "https://projects.machinekind.ai/mcp",
      "headers": { "Authorization": "Bearer YOUR_TOKEN" }
    }
  }
}
```

Save the file and restart Antigravity.

## 3. Check the connection

Ask your agent "Who am I in OpenProject?". It should call the `current_user` tool and answer with your name.

| Problem | Fix |
|---|---|
| HTTP 401 | The token is wrong or revoked. Create a new token and replace the old one. |
| The server is missing or has no tools | Restart the client. |
| You need to replace the token in Claude Code | Run `claude mcp remove --scope user openproject-prod`, then add it again. |
| You need to replace the token in Codex or Antigravity | Edit the token in the config file. Running the Codex snippet again adds a duplicate entry. |

## License

This is a modified version of [OpenProject](https://github.com/opf/openproject). Machinekind has changed it since
2026-10-04. The changes unlock the MCP server and the Design settings without an Enterprise token, add MCP tools for
project setup and apply the Machinekind brand. This fork is not affiliated with or endorsed by OpenProject GmbH.

OpenProject is licensed under the GNU General Public License version 3. See [LICENSE](LICENSE) and
[COPYRIGHT](COPYRIGHT).

The OpenProject icon font is by the OpenProject Foundation (OPF), <https://www.openproject.org>. It is licensed under
the [Creative Commons Attribution 3.0 Unported License](https://creativecommons.org/licenses/by/3.0/) and uses icons
from the [Minicons](http://www.webalys.com/minicons) pack by webalys.
