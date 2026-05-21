# AIDEN Releases

Distribution channel for AIDEN — desktop builds AND the native Linux
self-host runtime.

## Desktop builds

| Platform | Download |
| --- | --- |
| 🍎 macOS (Apple Silicon)  | [Releases page](https://github.com/Kylianmgt/aiden-releases/releases) |
| 🪟 Windows (x64)          | [Releases page](https://github.com/Kylianmgt/aiden-releases/releases) |

More info: [aidenapp.org](https://aidenapp.org)

---

## Self-host on a Linux VPS

Run AIDEN as a normal systemd service on Ubuntu / Debian / Fedora /
RHEL, fronted by Caddy with auto-LetsEncrypt. No Docker. Open
`https://your-domain/` in any browser, log in, use it.

### One-liner install

```bash
curl -fsSL https://raw.githubusercontent.com/Kylianmgt/aiden-releases/main/install.sh \
  | sudo bash -s -- --domain aiden.example.com
```

What it does:

1. Installs Node 20 (via NodeSource) + Caddy (via Caddy's official repo)
   if missing. Skipped when already present.
2. Creates an `aiden` system user.
3. Downloads the latest pre-built AIDEN runtime tarball from this repo's
   releases (~80 MB).
4. Extracts to `/opt/aiden`, preserving `/opt/aiden/data` across upgrades
   (your SQLite DB + CLI OAuth tokens).
5. Installs the Claude Code + Codex CLIs globally via npm so AIDEN can
   spawn them at runtime.
6. Drops a hardened `aiden.service` systemd unit and starts it.
7. Drops a Caddyfile snippet that routes `/v1/*` to the mobile bridge
   and everything else to the web server.
8. Waits for `/api/health`, then prints your first-launch `/setup` URL.

### Flags

```bash
sudo bash install.sh \
  --domain     aiden.example.com    # required when using Caddy
  --release    latest                # or a specific tag, e.g. v1.6.0
  --port       3000                  # internal web port
  --bridge-port 3001                 # internal mobile bridge port
  --home       /opt/aiden            # install dir
  --no-caddy                         # use your own reverse proxy
  --pin-mode   public_ca             # spki | public_ca (auto by default)
  --upgrade                          # pull latest, restart service
  --uninstall                        # stop + remove everything
```

### After install

1. **Set a password.** Open the printed setup URL, type a password, log in.
2. **Sign in to the AI provider CLIs.** Settings → AI Providers →
   "Provider CLIs" card → **Sign in** on Claude Code and Codex. The CLI
   OAuth URL prints into a streamed console; click the **Open URL**
   button to complete the flow in your own browser.
3. **(Optional) Pair the iOS app.** Settings → Mobile → Pair device.
   The QR points at your domain — scan and pair from anywhere.

### Upgrade

Re-run the installer with `--upgrade`. It fetches the latest release,
swaps the runtime, and restarts the service. Your `/opt/aiden/data`
volume (SQLite DB, CLI OAuth tokens) is preserved.

```bash
curl -fsSL https://raw.githubusercontent.com/Kylianmgt/aiden-releases/main/install.sh \
  | sudo bash -s -- --upgrade --domain aiden.example.com
```

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/Kylianmgt/aiden-releases/main/install.sh \
  | sudo bash -s -- --uninstall
```

Removes the systemd unit, the `aiden` user, and `/opt/aiden` including
the data dir. Caddy is left installed since you may use it for other
sites — remove with your distro's package manager if unneeded.

### Troubleshooting

| Symptom | Fix |
| --- | --- |
| Setup URL printed once, then I missed it | `systemctl restart aiden && journalctl -u aiden -n 20 \| grep "Setup URL"` |
| 502 from Caddy | `journalctl -u aiden -n 100` — the node process is crash-looping. Look for `MODULE_NOT_FOUND` or migration errors. |
| Caddy not issuing TLS | Verify DNS A-record points at the VPS and ports 80 + 443 are open. `journalctl -u caddy -n 100`. |
| `claude` / `codex` CLI sign-in fails | The CLI ran fine but couldn't auth. Try `sudo -u aiden /usr/bin/node -e "console.log(process.env.HOME)"` to confirm $HOME is `/opt/aiden`; re-run sign-in from Settings. |

### Repos

- **Self-host runtime + install.sh:** [Kylianmgt/aiden-releases](https://github.com/Kylianmgt/aiden-releases)
- **Source (private):** Kylianmgt/aiden-v2-desktop
- **Docs site:** [aidenapp.org](https://aidenapp.org)
