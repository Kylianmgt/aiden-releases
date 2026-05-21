#!/usr/bin/env bash
# AIDEN — native Linux installer (no Docker).
#
# Downloads a pre-built AIDEN runtime from this repo's releases, installs
# Node 20 + Caddy via the system package manager if missing, sets AIDEN
# up as a systemd service, and configures Caddy to serve it over HTTPS
# with auto-LetsEncrypt at your domain.
#
# Result: open `https://<your-domain>/` in any browser from anywhere,
# log in, use AIDEN. No Docker, no compose, no build on the host.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/Kylianmgt/aiden-releases/main/install.sh \
#     | sudo bash -s -- --domain aiden.example.com
#
# Flags:
#   --domain <fqdn>     Public hostname (required when using Caddy).
#   --release <tag>     Specific release tag to install. Default: latest.
#   --port <n>          Web server port (default 3000, loopback only).
#   --bridge-port <n>   Mobile bridge port (default 3001, loopback only).
#   --home <dir>        Install dir (default /opt/aiden).
#   --no-caddy          Skip Caddy. Bind ports publicly; you handle TLS.
#   --pin-mode <mode>   spki | public_ca (default public_ca with Caddy).
#   --upgrade           Pull latest release, replace binary, restart.
#   --uninstall         Stop service, remove install dir + service unit.
#   --help              Show this message.
#
# Supported distros:
#   - Debian 11+ / Ubuntu 20.04+
#   - Fedora 37+ / RHEL 9+ / Rocky / Alma
#   - (Arch / Alpine — install Node + Caddy yourself first, then re-run
#     with --no-system-deps once that flag lands; PRs welcome.)
#
# Source: https://github.com/Kylianmgt/aiden-releases
# Issues: https://github.com/Kylianmgt/aiden-releases/issues

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────

REPO_OWNER="Kylianmgt"
REPO_NAME="aiden-releases"
ARCH="linux-x64"
DEFAULT_HOME="/opt/aiden"
DEFAULT_RELEASE="latest"
DEFAULT_PORT="3000"
DEFAULT_BRIDGE_PORT="3001"
SERVICE_USER="aiden"
SERVICE_NAME="aiden"

DOMAIN=""
RELEASE_TAG=""
WEB_PORT=""
BRIDGE_PORT=""
AIDEN_HOME=""
USE_CADDY="auto"     # auto | yes | no
PIN_MODE=""
UPGRADE_MODE="0"
UNINSTALL_MODE="0"

# ─── Pretty output ──────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log()  { printf '%s[aiden]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() { sed -n '2,42p' "$0"; exit 0; }

# ─── Arg parsing ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)       DOMAIN="$2"; shift 2 ;;
    --release)      RELEASE_TAG="$2"; shift 2 ;;
    --port)         WEB_PORT="$2"; shift 2 ;;
    --bridge-port)  BRIDGE_PORT="$2"; shift 2 ;;
    --home)         AIDEN_HOME="$2"; shift 2 ;;
    --no-caddy)     USE_CADDY="no"; shift ;;
    --with-caddy)   USE_CADDY="yes"; shift ;;
    --pin-mode)     PIN_MODE="$2"; shift 2 ;;
    --upgrade)      UPGRADE_MODE="1"; shift ;;
    --uninstall)    UNINSTALL_MODE="1"; shift ;;
    --help|-h)      usage ;;
    *)              die "Unknown flag: $1 (try --help)" ;;
  esac
done

RELEASE_TAG="${RELEASE_TAG:-$DEFAULT_RELEASE}"
WEB_PORT="${WEB_PORT:-$DEFAULT_PORT}"
BRIDGE_PORT="${BRIDGE_PORT:-$DEFAULT_BRIDGE_PORT}"
AIDEN_HOME="${AIDEN_HOME:-$DEFAULT_HOME}"

if [[ "$USE_CADDY" == "auto" ]]; then
  if [[ -n "$DOMAIN" ]]; then USE_CADDY="yes"; else USE_CADDY="no"; fi
fi

if [[ -z "$PIN_MODE" ]]; then
  if [[ "$USE_CADDY" == "yes" ]]; then PIN_MODE="public_ca"; else PIN_MODE="spki"; fi
fi

[[ "$(id -u)" != "0" ]] && die "Run as root or via sudo. Service + Caddy install requires it."

# ─── Distro detection ───────────────────────────────────────────────────────

PKG_FAMILY="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) PKG_FAMILY="debian" ;;
    *fedora*|*rhel*|*centos*|*rocky*|*alma*) PKG_FAMILY="rhel" ;;
  esac
fi
log "Detected package family: $PKG_FAMILY ($(uname -m))"

# ─── Uninstall ──────────────────────────────────────────────────────────────

if [[ "$UNINSTALL_MODE" == "1" ]]; then
  log "Uninstalling AIDEN — stopping service + removing $AIDEN_HOME"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f /etc/systemd/system/$SERVICE_NAME.service
  systemctl daemon-reload
  if id "$SERVICE_USER" &>/dev/null; then
    userdel "$SERVICE_USER" 2>/dev/null || true
  fi
  rm -rf "$AIDEN_HOME"
  if [[ "$USE_CADDY" == "yes" && -n "$DOMAIN" ]]; then
    if [[ -f /etc/caddy/Caddyfile.d/aiden.caddy ]]; then
      rm -f /etc/caddy/Caddyfile.d/aiden.caddy
      systemctl reload caddy 2>/dev/null || true
    fi
  fi
  ok "AIDEN uninstalled. Caddy is left running for other sites; remove it manually if unneeded."
  exit 0
fi

# ─── Install system deps ────────────────────────────────────────────────────

install_node() {
  if command -v node &>/dev/null; then
    local v
    v="$(node --version | sed 's/^v//')"
    if [[ "${v%%.*}" -ge 18 ]]; then
      ok "Node $(node --version) already installed"
      return 0
    fi
    warn "Existing Node ($v) is too old; installing Node 20"
  fi
  case "$PKG_FAMILY" in
    debian)
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs
      ;;
    rhel)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      dnf install -y nodejs || yum install -y nodejs
      ;;
    *)
      die "Auto-install of Node 20 isn't supported on this distro. Install nodejs >= 18 manually then re-run."
      ;;
  esac
  ok "Node $(node --version) installed"
}

install_caddy() {
  if command -v caddy &>/dev/null; then
    ok "Caddy already installed ($(caddy version | head -1))"
    return 0
  fi
  case "$PKG_FAMILY" in
    debian)
      # Cloudsmith-hosted official Caddy apt repo.
      apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
        > /etc/apt/sources.list.d/caddy-stable.list
      apt-get update
      apt-get install -y caddy
      ;;
    rhel)
      dnf install -y 'dnf-command(copr)' || yum install -y dnf-plugins-core
      dnf copr enable -y @caddy/caddy
      dnf install -y caddy
      ;;
    *)
      die "Caddy auto-install isn't supported on this distro. Install caddy manually then re-run."
      ;;
  esac
  systemctl enable --now caddy
  ok "Caddy installed and running"
}

install_aux() {
  case "$PKG_FAMILY" in
    debian) apt-get update && apt-get install -y curl tar ca-certificates jq git ;;
    rhel)   dnf install -y curl tar ca-certificates jq git || yum install -y curl tar ca-certificates jq git ;;
  esac
}

install_aux
install_node

if [[ "$USE_CADDY" == "yes" ]]; then
  [[ -z "$DOMAIN" ]] && die "--domain is required when Caddy is in front."
  install_caddy
fi

# ─── Service user ───────────────────────────────────────────────────────────

if ! id "$SERVICE_USER" &>/dev/null; then
  useradd --system --home "$AIDEN_HOME" --shell /usr/sbin/nologin "$SERVICE_USER"
  ok "Created system user '$SERVICE_USER'"
fi

# ─── Download + extract runtime tarball ─────────────────────────────────────

mkdir -p "$AIDEN_HOME"
TMP_DIR="$(mktemp -d -t aiden-install.XXXXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$RELEASE_TAG" == "latest" ]]; then
  # Resolve "latest" to the actual highest semver tag via GH API. Falls
  # back to the literal "latest" release tag we maintain on stable channels.
  RESOLVED_TAG="$(curl -fsSL "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" | jq -r '.tag_name' 2>/dev/null || true)"
  if [[ -z "$RESOLVED_TAG" || "$RESOLVED_TAG" == "null" ]]; then
    RESOLVED_TAG="latest"
  fi
else
  RESOLVED_TAG="$RELEASE_TAG"
fi
log "Installing release: $RESOLVED_TAG"

TAR_NAME="aiden-${ARCH}-${RESOLVED_TAG}.tar.gz"
# Stable "latest" release has the asset renamed to aiden-linux-x64-latest.tar.gz
if [[ "$RESOLVED_TAG" == "latest" ]]; then
  TAR_NAME="aiden-${ARCH}-latest.tar.gz"
fi
TAR_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$RESOLVED_TAG/$TAR_NAME"
SHA_URL="$TAR_URL.sha256"
TAR_FILE="$TMP_DIR/$TAR_NAME"

log "Downloading $TAR_URL"
if ! curl -fL --progress-bar -o "$TAR_FILE" "$TAR_URL"; then
  die "Failed to download $TAR_URL. Check the release exists at https://github.com/$REPO_OWNER/$REPO_NAME/releases/$RESOLVED_TAG"
fi

if curl -fsSL -o "$TAR_FILE.sha256" "$SHA_URL" 2>/dev/null; then
  EXPECTED=$(awk '{print $1}' "$TAR_FILE.sha256")
  ACTUAL=$(sha256sum "$TAR_FILE" | awk '{print $1}')
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    die "sha256 mismatch on downloaded tarball — refusing to install. expected=$EXPECTED actual=$ACTUAL"
  fi
  ok "sha256 verified ($EXPECTED)"
else
  warn "No .sha256 sidecar found for this release — skipping integrity check."
fi

log "Extracting into $AIDEN_HOME"
# Wipe the runtime layout (but preserve /opt/aiden/data which holds the
# SQLite DB + CLI OAuth tokens across upgrades).
find "$AIDEN_HOME" -mindepth 1 -maxdepth 1 ! -name 'data' -exec rm -rf {} +
tar -xzf "$TAR_FILE" -C "$AIDEN_HOME"
mkdir -p "$AIDEN_HOME/data" "$AIDEN_HOME/data/mobile-bridge"

# Inject an `electron` stub package into node_modules. Several main-process
# modules in the runtime (database → default-agents → agent-workspace,
# license, widget-runtime) do a top-level `import { app, BrowserWindow,
# ipcMain } from 'electron'`. In headless mode none of the Electron-only
# methods get CALLED — but the import resolution itself fails at boot with
# MODULE_NOT_FOUND because electron isn't a prod dep. The stub satisfies
# the require and throws a loud error only if something tries to USE a
# desktop-only API (telling us exactly where to refactor through HostEnv).
log "Installing electron stub for headless require resolution"
STUB_DIR="$AIDEN_HOME/node_modules/electron"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/package.json" <<'STUBJSON'
{"name":"electron","version":"0.0.0-headless","main":"index.js"}
STUBJSON
cat > "$STUB_DIR/index.js" <<'STUBJS'
// Headless stub for the AIDEN web server. Anything Electron-specific that
// actually gets CALLED here is a bug — refactor the call site through
// services/mobile-bridge/host-env.ts so it works in both modes.
const noop = () => undefined;
const headlessGuard = (name) => () => {
  throw new Error(`[electron-stub] '${name}' called in headless web mode. ` +
    `If you see this, refactor the call site to route through HostEnv ` +
    `(electron/main/services/mobile-bridge/host-env.ts) or otherwise guard ` +
    `against Electron-only APIs.`);
};

class HeadlessBrowserWindow {
  static getAllWindows() { return []; }
  constructor() { throw new Error('[electron-stub] new BrowserWindow() in headless mode'); }
}
class HeadlessNotification {
  constructor() {}
  show() {}
  on() {}
}

module.exports = {
  app: {
    isPackaged: false,
    getVersion: () => process.env.npm_package_version || 'server-mode',
    getPath: headlessGuard('app.getPath'),
    getAppPath: () => process.cwd(),
    on: noop,
    once: noop,
    off: noop,
    removeAllListeners: noop,
    whenReady: () => Promise.resolve(),
    quit: noop,
    exit: noop,
    setLoginItemSettings: noop,
    commandLine: { appendSwitch: noop, appendArgument: noop },
  },
  BrowserWindow: HeadlessBrowserWindow,
  ipcMain: {
    handle: noop, handleOnce: noop, on: noop, once: noop, off: noop,
    removeAllListeners: noop, removeHandler: noop,
  },
  ipcRenderer: { on: noop, send: noop, invoke: () => Promise.resolve(null) },
  Notification: HeadlessNotification,
  shell: {
    openExternal: () => Promise.resolve(),
    showItemInFolder: noop,
    openPath: () => Promise.resolve(''),
  },
  dialog: {
    showOpenDialog: () => Promise.resolve({ canceled: true, filePaths: [] }),
    showSaveDialog: () => Promise.resolve({ canceled: true }),
    showMessageBox: () => Promise.resolve({ response: 0 }),
  },
  Menu: { setApplicationMenu: noop, buildFromTemplate: () => ({ popup: noop }) },
  MenuItem: class {},
  Tray: class { constructor() { throw new Error('[electron-stub] new Tray() in headless mode') } },
  nativeImage: {
    createEmpty: () => ({}),
    createFromPath: () => ({}),
    createFromDataURL: () => ({}),
  },
  protocol: {
    handle: noop, registerSchemesAsPrivileged: noop, registerFileProtocol: noop,
  },
  session: {
    defaultSession: { webRequest: { onBeforeRequest: noop, onHeadersReceived: noop } },
  },
  systemPreferences: { getMediaAccessStatus: () => 'granted' },
  powerMonitor: { on: noop, addListener: noop },
  autoUpdater: { on: noop, checkForUpdates: noop },
  screen: { getPrimaryDisplay: () => ({ workAreaSize: { width: 1440, height: 900 } }), on: noop },
  globalShortcut: { register: noop, unregister: noop, unregisterAll: noop },
  clipboard: { readText: () => '', writeText: noop },
};
STUBJS

chown -R "$SERVICE_USER:$SERVICE_USER" "$AIDEN_HOME"

# Install the AI provider CLIs globally so the AIDEN runtime can spawn
# them. claude-code + codex are tiny (~50MB combined); we install them
# to a service-user-owned global prefix so the systemd unit can call
# them without privilege escalation.
log "Installing Claude Code + Codex CLIs globally via npm"
if ! npm list -g --depth=0 2>/dev/null | grep -qE '@anthropic-ai/claude-code'; then
  npm install -g @anthropic-ai/claude-code || warn "claude CLI install failed — sign-in from Settings will fail until fixed"
fi
if ! npm list -g --depth=0 2>/dev/null | grep -qE '@openai/codex'; then
  npm install -g @openai/codex || warn "codex CLI install failed — sign-in from Settings will fail until fixed"
fi

# ─── Public URL + bridge config ─────────────────────────────────────────────

PUBLIC_URL="http://localhost:$WEB_PORT"
if [[ "$USE_CADDY" == "yes" && -n "$DOMAIN" ]]; then
  PUBLIC_URL="https://$DOMAIN"
elif [[ "$USE_CADDY" == "no" && -n "$DOMAIN" ]]; then
  PUBLIC_URL="https://$DOMAIN"
fi

# ─── systemd unit ───────────────────────────────────────────────────────────

cat > "/etc/systemd/system/$SERVICE_NAME.service" <<UNIT
# Generated by aiden-releases/install.sh — re-run the installer to refresh.

[Unit]
Description=AIDEN headless web server + mobile bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$AIDEN_HOME
ExecStart=/usr/bin/node $AIDEN_HOME/dist-web/web/server.js

# Loopback bind when Caddy is in front; public bind otherwise.
Environment=NODE_ENV=production
Environment=PORT=$WEB_PORT
Environment=AIDEN_BRIDGE_PORT=$BRIDGE_PORT
Environment=AIDEN_BRIDGE_BIND=loopback
Environment=AIDEN_BRIDGE_STATE_DIR=$AIDEN_HOME/data/mobile-bridge
Environment=AIDEN_PUBLIC_URL=$PUBLIC_URL
Environment=AIDEN_BRIDGE_PIN_MODE=$PIN_MODE
Environment=AIDEN_DB_PATH=$AIDEN_HOME/data/aiden-local.db
Environment=HOME=$AIDEN_HOME

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$AIDEN_HOME
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
ok "systemd service $SERVICE_NAME installed and started"

# ─── Caddy site config ──────────────────────────────────────────────────────

if [[ "$USE_CADDY" == "yes" ]]; then
  mkdir -p /etc/caddy/Caddyfile.d
  # Make sure /etc/caddy/Caddyfile imports per-site snippets. If the
  # admin already has a custom Caddyfile we don't touch it; we just drop
  # the AIDEN site config in the conf.d directory and append the import
  # exactly once.
  if [[ ! -f /etc/caddy/Caddyfile ]]; then
    cat > /etc/caddy/Caddyfile <<'CADDY_MAIN'
# Default AIDEN Caddyfile. Site configs live in Caddyfile.d/.
import Caddyfile.d/*.caddy
CADDY_MAIN
  elif ! grep -qE '^\s*import\s+Caddyfile\.d/' /etc/caddy/Caddyfile; then
    echo "" >> /etc/caddy/Caddyfile
    echo "import Caddyfile.d/*.caddy" >> /etc/caddy/Caddyfile
  fi

  cat > /etc/caddy/Caddyfile.d/aiden.caddy <<CADDY_SITE
# Generated by aiden-releases/install.sh — re-run to refresh.
#
# AIDEN serves browsers AND paired iOS phones on this single hostname.
# Caddy auto-fetches a LetsEncrypt cert on first hit. The mobile bridge
# at $BRIDGE_PORT and the web server at $WEB_PORT both listen on
# loopback only (see systemd unit); only Caddy is exposed publicly.

$DOMAIN {
    # Mobile bridge — paired iOS clients (/v1/pair/*, /v1/stream WS).
    reverse_proxy /v1/* 127.0.0.1:$BRIDGE_PORT

    # Web push WS gateway used by the browser SPA.
    reverse_proxy /api/ws 127.0.0.1:$WEB_PORT

    # Everything else — SPA static + /api/* REST.
    reverse_proxy 127.0.0.1:$WEB_PORT
}
CADDY_SITE

  # Validate before reload so we never break a running Caddy.
  if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    systemctl reload caddy
    ok "Caddy reloaded with AIDEN site for $DOMAIN"
  else
    warn "Caddy config validation failed — run 'caddy validate --config /etc/caddy/Caddyfile' for details"
  fi
fi

# ─── Wait for health, surface setup URL ─────────────────────────────────────

log "Waiting for AIDEN to report healthy…"
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$WEB_PORT/api/health" >/dev/null 2>&1; then
    ok "AIDEN is responding on 127.0.0.1:$WEB_PORT"
    break
  fi
  sleep 2
  if [[ $i -eq 60 ]]; then
    warn "AIDEN didn't respond within 120s — check 'journalctl -u $SERVICE_NAME -n 100'"
  fi
done

SETUP_URL=""
SETUP_LINE=$(journalctl -u "$SERVICE_NAME" --since "5 minutes ago" 2>/dev/null | grep -E "Setup URL" | tail -1 || true)
if [[ -n "$SETUP_LINE" ]]; then
  RAW_URL=$(echo "$SETUP_LINE" | grep -oE 'https?://[^ ]+' | head -1)
  # journalctl gives us the URL with whatever the server printed (e.g.
  # the AIDEN_PUBLIC_URL). It's already correct in 99% of cases.
  SETUP_URL="$RAW_URL"
fi

cat <<BANNER

${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}
${C_BOLD}AIDEN is installed and running.${C_RESET}

  Web SPA + API : ${PUBLIC_URL}/
  Mobile bridge : ${PUBLIC_URL}/v1/*  (paired iOS clients)
  Health check  : ${PUBLIC_URL}/api/health
  Service       : systemctl status $SERVICE_NAME
  Logs          : journalctl -u $SERVICE_NAME -f
BANNER

if [[ -n "$SETUP_URL" ]]; then
  cat <<BANNER

${C_BOLD}First-launch setup required.${C_RESET}
Open this URL in a browser, set a password, then log in:

  ${C_GREEN}${SETUP_URL}${C_RESET}

The token is single-use and expires after 24h. If you miss it:
  systemctl restart $SERVICE_NAME && journalctl -u $SERVICE_NAME -n 20 | grep "Setup URL"
BANNER
else
  cat <<BANNER

${C_BOLD}Auth already configured.${C_RESET} Log in at: ${C_GREEN}${PUBLIC_URL}/login${C_RESET}
BANNER
fi

cat <<BANNER

${C_BOLD}Common commands:${C_RESET}
  bash <(curl -fsSL https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/install.sh) --upgrade --domain $DOMAIN
  systemctl restart $SERVICE_NAME
  bash <(curl -fsSL https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/main/install.sh) --uninstall

${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}
BANNER
