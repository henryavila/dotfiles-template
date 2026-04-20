# Syncthing setup — pairing + folders (`~/.claude/` + `~/.claude-mem/`)

Step-by-step guide for wiring up sync across N personal machines. **Prerequisite:** Syncthing is already installed and running on each machine (via topic `80-claude-code` in `dev-bootstrap`). Verify with:

```bash
systemctl --user is-active syncthing.service   # Linux/WSL
brew services list | grep syncthing            # Mac
pgrep -f 'syncthing serve'                     # universal fallback
```

---

## Mental model

You'll configure **2 separate folders** in Syncthing on each machine:

| Folder ID | Path | Content | `.stignore` |
|-----------|------|---------|-------------|
| `claude-config` | `~/.claude` | skills, agents, commands, rules, hooks, marketplaces, settings.json | `claude/stignore/claude-config.stignore` |
| `claude-mem` | `~/.claude-mem` | SQLite DB + chroma embeddings | `claude/stignore/claude-mem.stignore` |

Splitting into two folders gives granular control: you can pause one (e.g. during a claude-mem DB merge) without affecting the other.

---

## Phase 1 — Setup on the "golden machine" (M1)

Pick one machine as the initial source of truth (usually the most up-to-date one).

1. **Open the Web UI:** http://localhost:8384

2. **Set a password** (Settings → GUI):
   - User Name: `henry` (or anything)
   - Password: generate one from your password manager
   - Use HTTPS: on (optional)

3. **Grab the Device ID** (Actions → Show ID):
   - Save it — you'll use it on the other machines.

4. **Add the `claude-config` folder** (Add Folder):
   - Folder ID: `claude-config`  ← important, used on every machine
   - Folder Path: `/home/<user>/.claude` (or `/Users/<user>/.claude` on Mac)
   - Folder Type: **Send Only** ← CRITICAL during this initial phase
   - Ignore Patterns: **paste the contents of `~/dotfiles/claude/stignore/claude-config.stignore`**
   - Save

5. **Add the `claude-mem` folder:**
   - Folder ID: `claude-mem`
   - Folder Path: `/home/<user>/.claude-mem`
   - Folder Type: **Send Only**
   - Ignore Patterns: paste `claude/stignore/claude-mem.stignore`
   - Save

---

## Phase 2 — Setup on each receiving machine (M2, M3, M4)

**⚠️ IMPORTANT:** before pairing, **move the existing `~/.claude/` and `~/.claude-mem/`** to a local backup — Syncthing will overwrite them with M1's content.

```bash
mv ~/.claude ~/.claude.pre-sync-$(date +%Y%m%d)
mv ~/.claude-mem ~/.claude-mem.pre-sync-$(date +%Y%m%d)
mkdir -p ~/.claude ~/.claude-mem
```

(You already have a full `.tgz` backup from Phase 0 of the playbook; this `mv` is redundant but cheap extra insurance.)

1. **Open the Web UI:** http://localhost:8384

2. **Add device M1** (Add Remote Device):
   - Device ID: paste M1's ID
   - Name: `m1-hostname` (any label)
   - Introducer: **off** initially (turn it on once everything works — it simplifies pairing future machines)
   - Save

3. **Accept the folders M1 shares** (shows up as a notification after M1 shares):
   - `claude-config` → Folder Type: **Receive Only**; Path: `~/.claude`
   - `claude-mem` → Folder Type: **Receive Only**; Path: `~/.claude-mem`
   - Save

4. **On M1**, accept the share back (a notification appears):
   - Share `claude-config` with M2 → Save
   - Share `claude-mem` with M2 → Save

5. **Wait for sync to finish** — the folder shows "Up to Date" in the status. Takes 5–30 min depending on size + network.

Repeat steps 1–5 for M3, M4. Once the first machine is up, you can enable **Introducer** on M1 — then M2, M3, M4 automatically know each other without you having to pair every pair manually.

---

## Phase 3 — Flip to bidirectional (after sync + validation)

Once every machine shows "Up to Date" across both folders:

**On M1** (Web UI → folder → Edit):
- `claude-config` Folder Type: **Send & Receive** (was Send Only)
- `claude-mem` Folder Type: **Send & Receive**

**On M2, M3, M4:**
- `claude-config` Folder Type: **Send & Receive** (was Receive Only)
- `claude-mem` Folder Type: **Send & Receive**

From this point on: any change on any machine propagates to the others. **Zero manual intervention day-to-day.**

---

## Daily operation

There isn't any. Install a skill/plugin/mcp on any machine, Syncthing propagates in seconds-to-minutes.

**Convention:** avoid operating Claude Code on two machines *simultaneously* in the same project. It's unlikely, but if both edit the same file (e.g. a skill's SKILL.md) at the same time, Syncthing generates conflict files (`sync-conflict-<ts>-<device>.md`). Resolution: open both, keep the better one, delete the other.

---

## Troubleshooting

### "Folder shows 'Out of Sync' permanently"

Likely a conflict file or bad permissions. Web UI → folder → lists problematic files. Resolve file by file.

### "New machine doesn't show up in the device list"

- Firewall blocking port 22000 (TCP sync) or 21027 (UDP discovery)?
- Corporate networks can block Syncthing — try a relay: Settings → Connections → enable relays.

### "claude-mem DB corrupt after sync"

WAL/shm being synced despite `.stignore`? Check:
```bash
ls -la ~/.claude-mem/*.db-*
```
If `.db-shm` or `.db-wal` show up in the folder, the `.stignore` isn't matching. Verify:
```bash
cat ~/.claude-mem/.stignore
```

### "Many modified files, I want to see which ones"

Web UI → folder → "Failed" / "Out of Sync" shows the list. Also:
```bash
syncthing --logflags=0 --verbose
```

---

## Temporary pause (e.g. during a manual merge)

Web UI → folder → Pause. Resume afterwards.

CLI alternative:
```bash
curl -X POST -H "X-API-Key: $(grep api-key ~/.config/syncthing/config.xml | sed 's/.*<apikey>//' | sed 's/<.*//')" \
  http://localhost:8384/rest/db/pause -d 'folder=claude-config'
```

(API key lives in `~/.config/syncthing/config.xml` — `<apikey>` tag.)
