# Digital Home Extras

Features for a Digital Home, shared by Millionaire Mindware. Each folder is one feature,
packaged as a skill: a `SKILL.md` your agent follows step by step, plus the files it needs.

| Feature | What it does | Version |
|---------|--------------|---------|
| [vps-agents](vps-agents/) | Run your Buzz agents on your own Linux server, with an hourly security watchdog | 0.1.0 (draft) |

## Using a feature

Tell your agent: "Install `<feature>` from the Digital Home Extras library", and give it
this repository's address. It reads that folder's `SKILL.md` and walks you through it.

Each `SKILL.md` carries a `version` in its header. Your agent can compare it with the copy
it used last time to see if there is something newer.

## Rules every feature follows

- No secrets, addresses or personal details in this repository. Each owner uses their own
  accounts and keys.
- Nothing destructive without the owner's yes. Every feature lists its undo.
- Tested on a clean setup before it leaves draft.

**vps-agents is a draft.** It is the scripted form of a setup that runs in production, but
`server-setup.sh` has not yet been run end to end on a fresh server. Expect rough edges.

## Use at your own risk

These are community features, not official Buzz or BraveBrand software. Read the limits at
the top of each `SKILL.md` before you start.
