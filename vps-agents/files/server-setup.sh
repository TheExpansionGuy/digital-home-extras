#!/usr/bin/env bash
# server-setup.sh: prepare a fresh Ubuntu 24.04 server to run Buzz agents.
#
#   sudo bash server-setup.sh
#
# Run as root on the server, from the folder holding the other files in vps-agents/files.
# Safe to run again: every step checks before it changes anything.
#
# What it does, in order:
#   1. Patches the system and installs ufw, fail2ban, unattended-upgrades, jq, python3.
#   2. Locks SSH to key-only logins (refuses if root has no SSH key on file).
#   3. Firewall: deny incoming, allow outgoing, SSH only. fail2ban on SSH.
#   4. Creates the unprivileged `buzz` user that runs the agents.
#   5. Installs the Buzz runner (buzz, buzz-acp) from the official release, checksum verified.
#   6. Installs Node.js (checksum verified), Claude Code and the Claude agent runner for `buzz`.
#   7. Installs the server watchdog (timer stays off until its alarm line is set).
#
# It never opens a port, stores no secret, and signs nothing in.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

# Pinned versions. Change them together and re-test on a clean server.
BUZZ_VERSION=0.5.28
BUZZ_DEB_URL="https://github.com/block/buzz/releases/download/desktop-v${BUZZ_VERSION}/Buzz_${BUZZ_VERSION}_amd64.deb"
BUZZ_DEB_SHA256=53609fa586a787871f080b0bfce679633e457f650982411c81ba104648c388cb
NODE_VERSION=22.23.3
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
CLAUDE_CODE_PKG="@anthropic-ai/claude-code@2.1.296"
CLAUDE_ACP_PKG="@agentclientprotocol/claude-agent-acp@0.89.1"

HERE="$(cd "$(dirname "$0")" && pwd)"
say()  { printf '\n== %s\n' "$*"; }
fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

fetch_verified() {  # url sha256 dest
    curl -fsSL --retry 3 -o "$3" "$1" || fail "could not download $1"
    echo "$2  $3" | sha256sum -c --quiet - || { rm -f "$3"; fail "checksum mismatch for $1"; }
}

# --- preflight ---------------------------------------------------------------
[ "$(id -u)" = 0 ] || fail "run this as root (sudo bash server-setup.sh)"
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] || fail "this script is tested on Ubuntu 24.04 only (found ${PRETTY_NAME:-unknown})"
[ "$(uname -m)" = x86_64 ] || fail "Buzz publishes Linux builds for x86_64 only (found $(uname -m))"
for f in server-watchdog server-watchdog.service server-watchdog.timer; do
    [ -f "$HERE/$f" ] || fail "missing $f next to this script"
done
grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys 2>/dev/null \
    || fail "root has no SSH key on file. Add your key first (ssh-copy-id), or locking SSH would lock you out."

# --- 1. patches and packages --------------------------------------------------
say "1/7 Patching the system and installing base packages"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
apt-get -y -q install ufw fail2ban unattended-upgrades jq curl python3 xz-utils ca-certificates

# --- 2. SSH: keys only ---------------------------------------------------------
say "2/7 Locking SSH to key-only logins"
HARDEN=/etc/ssh/sshd_config.d/00-hardening.conf
if [ ! -f "$HARDEN" ]; then
    cat > "$HARDEN" <<'EOF'
# Added by server-setup.sh. Keys only. Remove this file and reload ssh to undo.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    sshd -t || { rm -f "$HARDEN"; fail "SSH rejected the hardening file; nothing changed"; }
    systemctl reload ssh
    LOCKDOWN_AT="$(date '+%Y-%m-%d %H:%M:%S')"
else
    LOCKDOWN_AT=""
fi

# --- 3. firewall and fail2ban ----------------------------------------------------
say "3/7 Firewall (SSH only) and fail2ban"
ufw allow OpenSSH >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1

# --- 4. the buzz user -------------------------------------------------------------
say "4/7 Agent user 'buzz'"
id buzz >/dev/null 2>&1 || adduser --disabled-password --gecos "" buzz >/dev/null
install -d -m 700 -o buzz -g buzz /home/buzz/agents

# --- 5. Buzz runner -----------------------------------------------------------------
say "5/7 Buzz runner ${BUZZ_VERSION}"
install -d -m 755 /opt/buzz /opt/buzz/bin
if [ ! -x /opt/buzz/bin/buzz-acp ] || [ "$(cat /opt/buzz/.version 2>/dev/null)" != "$BUZZ_VERSION" ]; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    fetch_verified "$BUZZ_DEB_URL" "$BUZZ_DEB_SHA256" "$TMP/buzz.deb"
    dpkg-deb -x "$TMP/buzz.deb" "$TMP/x"   # files only; the desktop app is not installed
    for b in buzz buzz-acp buzz-agent git-credential-nostr; do
        install -m 755 "$TMP/x/usr/bin/$b" /opt/buzz/bin/$b
    done
    echo "$BUZZ_VERSION" > /opt/buzz/.version
    rm -rf "$TMP"; trap - EXIT
fi
/opt/buzz/bin/buzz-acp --help >/dev/null || fail "buzz-acp does not run on this server"

# --- 6. Node, Claude Code, Claude agent runner -----------------------------------------
say "6/7 Node.js ${NODE_VERSION}, Claude Code and the Claude agent runner"
if [ "$(/opt/node/bin/node --version 2>/dev/null)" != "v${NODE_VERSION}" ]; then
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    fetch_verified "$NODE_URL" "$NODE_SHA256" "$TMP/node.tar.xz"
    rm -rf /opt/node.new && mkdir /opt/node.new
    tar -xJf "$TMP/node.tar.xz" -C /opt/node.new --strip-components=1
    rm -rf /opt/node && mv /opt/node.new /opt/node
    rm -rf "$TMP"; trap - EXIT
fi
for b in node npm npx; do ln -sf /opt/node/bin/$b /usr/local/bin/$b; done
su - buzz -c "npm config set prefix \$HOME/.npm-global"
su - buzz -c "PATH=/usr/local/bin:/usr/bin:/bin npm install -g --no-fund --no-audit $CLAUDE_CODE_PKG $CLAUDE_ACP_PKG" >/dev/null
su - buzz -c 'grep -q npm-global ~/.profile || echo "PATH=\$HOME/.npm-global/bin:/opt/buzz/bin:\$PATH" >> ~/.profile'
su - buzz -c 'command -v claude-agent-acp >/dev/null' || fail "claude-agent-acp did not install for the buzz user"

# --- 7. watchdog ------------------------------------------------------------------------
say "7/7 Server watchdog"
install -m 755 "$HERE/server-watchdog" /usr/local/sbin/server-watchdog
install -m 644 "$HERE/server-watchdog.service" /etc/systemd/system/server-watchdog.service
install -m 644 "$HERE/server-watchdog.timer" /etc/systemd/system/server-watchdog.timer
install -d -m 700 /etc/server-watchdog
if [ ! -f /etc/server-watchdog/watchdog.conf ]; then
    {
        echo "# Local settings for server-watchdog. See the tunables at the top of /usr/local/sbin/server-watchdog."
        echo "# Contabo and some other hosts ship a cloud-init step that fails harmlessly on first boot."
        echo "# If 'systemctl --failed' shows cloud-init.service after setup, list it here."
        echo 'IGNORE_FAILED_UNITS=""'
        echo "# Logins before the SSH lockdown (e.g. the one-off ssh-copy-id) are not judged."
        echo "LOGINS_NOT_BEFORE=\"${LOCKDOWN_AT}\""
    } > /etc/server-watchdog/watchdog.conf
fi
systemctl daemon-reload

say "Done. Checks:"
echo "ssh password login: $(sshd -T | awk '/^passwordauthentication /{print $2}')"
echo "firewall:           $(ufw status | head -1)"
echo "public listeners:   $(ss -tlnH | awk '{print $4}' | grep -Ev '^(127\.|\[::1\])' | tr '\n' ' ')"
echo "fail2ban:           $(systemctl is-active fail2ban)"
echo "buzz runner:        $(cat /opt/buzz/.version)"
echo "node:               $(node --version)"
echo "claude agent:       $(su - buzz -c 'command -v claude-agent-acp')"
echo "failed units:       $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
echo
echo "Next: sign Claude in for the buzz user (see SKILL.md, Phase 3)."
