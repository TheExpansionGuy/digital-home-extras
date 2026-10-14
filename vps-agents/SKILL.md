---
name: vps-agents
description: Move your Buzz agents onto your own Linux server so they keep working when your computer is off. Use when the owner says "run my agents on a server", "set up the VPS", "agents on a VPS", or "install vps-agents". Hardens a fresh Ubuntu 24.04 server, installs the Buzz runner and Claude, adds a "vps" option to Buzz Desktop's Run on menu, and installs an hourly watchdog that raises an alarm in Buzz.
version: 0.1.0
buzz_version: 0.5.28
---

# VPS agents

Your owner wants agents that live on a server, not on their computer. You will walk them
through it **one step at a time**, with proof at every step. Never give the next step
until the current one is confirmed.

## Before you start: tell the owner the limits

Say these plainly, then ask if they want to go ahead:

- **Draft.** `server-setup.sh` has not yet been run end to end on a fresh server. If a step
  fails, stop, read the error, and fix it before going on.
- **Pinned to Buzz Desktop 0.5.28.** Check `Buzz > About` on their computer. A different
  version may not work. Do not proceed on another version without testing.
- **Unofficial.** Buzz is building an official SSH provider (block/buzz PR #3449). When it
  ships, switch to it.
- **New agents only.** Buzz Desktop 0.5.28 offers "Run on" only when an agent is created.
  An existing agent cannot be moved; it is recreated as a new identity.
- **Cost.** A server (about 8 GB RAM, x86_64) is a monthly bill. Claude runs on the owner's
  own Claude subscription, signed in on the server. Ask before anything is bought.

## Rules for you

- Nothing secret is pasted into chat. The owner types passwords and sign-ins into their own
  terminal. You never print keys, tokens, the agent private key, or the alarm secret.
- The server gets no open ports except SSH. Agents connect out to the relay; nothing connects in.
- One home per agent identity. Never run the same agent on the computer and the server at once.
- Every command below is run from the owner's computer unless it says otherwise.
  `HOST` is the server's IP address. Replace it in every command.

## Phase 0: order the server

Ask before anything is bought. The owner orders it in their own account; you never hold
their hosting login.

1. **Pick a host.** Any provider that sells a plain Linux server (often called a VPS) works.
   This kit runs in production on Contabo. Hetzner, DigitalOcean and Vultr sell the same thing.
2. **What to order:**
   - Operating system: **Ubuntu 24.04 LTS**. Plain. No control panel (no cPanel, Plesk,
     Webmin), no "apps" or one-click installs.
   - Processor type: **x86_64** (also called AMD64 or Intel). Not ARM: Buzz has no ARM build.
   - Size: **4 CPU cores, 8 GB RAM, 80 GB disk or more.** Smaller works for one quiet agent;
     8 GB leaves room for several.
   - Region: the one nearest the owner.
   - Extras: none needed. Skip backups add-ons, extra IPs and managed firewalls. Snapshots
     are worth having if the host offers them free.
3. **Root password:** the order form usually asks for one. Have the owner generate a long one
   in their password manager and save it there. They type it in their terminal once in
   Phase 1. It never goes in chat.
4. **Lock the hosting account:** have them switch on two-factor login in the provider's
   account settings. Whoever holds this account can wipe or take over the server.
5. **Find the address:** when the server is ready (minutes to a few hours), the provider
   emails it and shows it in the panel. Look for "IPv4 address" or "IP": four numbers
   separated by dots. That is `HOST` from here on. The address is fine to share in chat.

**Proof:** the panel shows the server as running, Ubuntu 24.04, and its IPv4 address.

## Phase 1: the server and the key

Prerequisites: the server from Phase 0, and its root password.

1. Ask if they have an SSH key: `ls ~/.ssh/id_ed25519.pub`. If not:
   `ssh-keygen -t ed25519` (press Enter through the questions; a passphrase is fine).
2. Put the key on the server: `ssh-copy-id root@HOST`. They type the root password once.
   The first connection shows a host key fingerprint. Ask them to compare it with the one in
   their provider's panel or console if it offers one.
3. **Proof:** `ssh -o BatchMode=yes root@HOST hostname` prints the server name with no
   password prompt.

## Phase 2: run the setup script

1. Get this folder onto their computer (clone the library, or download it), then copy the
   files across: `scp vps-agents/files/* root@HOST:/root/vps-agents/`
2. Run it: `ssh root@HOST 'bash /root/vps-agents/server-setup.sh'`
   It takes a few minutes. It stops with `STOPPED:` and a reason if anything is wrong.
3. **Proof:** the "Done. Checks:" block shows password login `no`, firewall `active`, only
   port 22 listening, fail2ban `active`, buzz runner `0.5.28`, and a path for claude agent.
4. **Proof from outside:** `ssh -o PubkeyAuthentication=no root@HOST` must be refused
   (Permission denied). Key login still works.
5. If "failed units" lists `cloud-init.service`, that is a known first-boot quirk on some
   hosts. Add it to `IGNORE_FAILED_UNITS` in `/etc/server-watchdog/watchdog.conf`.

## Phase 3: sign Claude in on the server

The owner does this themselves, in their own terminal:

`ssh -t root@HOST "su - buzz -c 'claude auth login'"`

It shows a link. They open it, approve, and paste the code back into the terminal (not into chat).

**Proof:** `ssh root@HOST "su - buzz -c 'claude auth status'"` shows signed in.

## Phase 4: add "vps" to Buzz Desktop

1. Install the provider:
   `mkdir -p ~/.local/bin && cp vps-agents/files/buzz-backend-vps ~/.local/bin/ && chmod 755 ~/.local/bin/buzz-backend-vps`
2. Check it: `echo '{"op":"info"}' | ~/.local/bin/buzz-backend-vps` returns `"ok": true, "name": "vps"`.
3. Quit and reopen Buzz Desktop.

## Phase 5: create the first server agent

1. In Buzz Desktop: create an agent. Open **Advanced**, set **Run on** to **vps**, and enter
   the server address `HOST`. Login user stays `root`.
2. Save. Desktop deploys it over SSH.
3. **Proof:** the owner DMs the new agent: "run `hostname` and tell me the result."
   It answers with the server's name. Exactly one reply.
4. **Proof on the server:** `ssh root@HOST 'systemctl list-units "buzz-agent@*" --no-legend'`
   shows one running unit.

To stop an agent: send it `!shutdown`. To remove it from the server:
`systemctl disable --now buzz-agent@<id>`, then delete `/home/buzz/agents/<id>`.

## Phase 6: the alarm line

The watchdog checks the server every hour (open ports, firewall, SSH settings, logins, keys,
failed services, disk, memory, patching) and posts to Buzz only when something changes.

1. Create a webhook workflow in the owner's DM with you. Replace the names with their exact
   Buzz display names:

   ```yaml
   name: 'Server watchdog alarm'
   description: 'The server watchdog calls this when a check fails.'
   trigger:
     on: webhook
   steps:
     - id: alarm
       action: send_message
       text: "**Server watchdog: {{trigger.level}}** on {{trigger.host}}, {{trigger.when}}\n\n{{trigger.summary}}\n\n@OWNER NAME @YOUR NAME"
   ```

   `buzz workflows create --help` shows the flags. The create response carries the
   `webhook_secret` **once**. It cannot be read again; if lost, delete and recreate.
2. Write it straight to the server without displaying it. The URL is
   `https://<relay host>/hooks/<workflow id>` (relay host = the relay URL without `wss://`).
   On the server, `/etc/server-watchdog/alarm.env`, mode 0600, owner root:
   ```
   ALARM_URL=https://<relay host>/hooks/<workflow id>
   ALARM_SECRET=<secret>
   ```
3. Test: `ssh root@HOST server-watchdog --test-alarm` posts a TEST message in the DM.
4. Accept today's state as known-good and switch the timer on:
   `ssh root@HOST 'server-watchdog --rebaseline && systemctl enable --now server-watchdog.timer'`
5. **Proof:** `ssh root@HOST server-watchdog --dry-run` prints `all clear`.

Optional: a weekly schedule workflow that asks you to run `server-watchdog --report` and
summarise it for the owner.

## Phase 7: hand over

Tell the owner, in plain words: what is running, how to stop an agent, that the watchdog
will post in the DM if anything changes, and the two limits (pinned version, unofficial).
Record the server address and what was installed in your own memory.

## Undo

- Agent: `systemctl disable --now buzz-agent@<id>`, delete `/home/buzz/agents/<id>`.
- Watchdog: `systemctl disable --now server-watchdog.timer`.
- SSH lock: delete `/etc/ssh/sshd_config.d/00-hardening.conf`, `systemctl reload ssh`.
- Provider: delete `~/.local/bin/buzz-backend-vps` and restart Buzz Desktop.
