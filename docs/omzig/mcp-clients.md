# omzig-mcp — Client Wiring

Spec §10.4 / §16.5. The `omzig-mcp` Azure Container App is provisioned by
`deployment/omzig` in the CIPP repo (see `ca-omzig-mcp-<env>`). The deploy
pipeline overwrites the placeholder hostnames below with the real ingress FQDN
on every release; until the first server image ships, these snippets are the
committed contract for how each client connects.

Auth model (§16.5 step 2): OAuth2 authorization-code + PKCE for Copilot
Studio; OAuth2 device-code for Claude Desktop / Claude Code / Codex CLI.
Delegated scopes only — no app-only `.default` tokens. Every write tool
defaults to `dry_run=true` and applies only with an `x-omzig-approval` token
(Appendix D).

## Claude Desktop (`claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "omzig-portal": {
      "type": "http",
      "url": "https://<omzig-mcp-ingress-fqdn>/mcp",
      "auth": { "flow": "device-code", "tenant": "<omzig-entra-tenant-id>" }
    }
  }
}
```

## Claude Code

```bash
claude mcp add --transport http omzig-portal https://<omzig-mcp-ingress-fqdn>/mcp
```

## Codex CLI (`~/.codex/mcp.json`)

```json
{
  "servers": {
    "omzig-portal": {
      "transport": "http",
      "url": "https://<omzig-mcp-ingress-fqdn>/mcp"
    }
  }
}
```

## Copilot Studio

Custom connector against `https://<omzig-mcp-ingress-fqdn>/mcp` with the
`omzig-mcp` Entra app registration (authorization-code + PKCE). Import the
OpenAPI description published at `/api/openapi.json`.

## One-command install

`omzig mcp install --client=claude|codex|copilot-studio` writes the snippet
for the chosen client with the real hostnames filled in (CLI milestone,
week 5).
