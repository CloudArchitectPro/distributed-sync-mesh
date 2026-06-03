# Troubleshooting

All six issues documented here were encountered and resolved in production. Each entry includes the exact symptom, root cause, and the specific fix.

---

## Issue 1 — Syncthing dead after reboot

### Symptom

Syncthing was running fine, but after a reboot the service never starts. Running `systemctl status syncthing@syncthing` shows:

```
● syncthing@syncthing.service
   Loaded: loaded (/lib/systemd/system/syncthing@.service)
   Active: failed
...
syncthing.service: Failed to determine user credentials: No such process
```

### Root cause

The `syncthing@.service` unit is a **template service** — the `@` means it requires a username suffix to know which user to run as. If you enable it as `syncthing@syncthing`, systemd looks for a user named `syncthing` on the system. If that user doesn't exist, the service fails silently on boot.

### Fix

Enable the service using **your actual username**, not the literal string `syncthing`:

```bash
# Disable the incorrectly-named service if it was set up wrong
sudo systemctl disable syncthing@syncthing

# Enable with your actual username
sudo systemctl enable syncthing@<your-username>
sudo systemctl start syncthing@<your-username>

# Verify
systemctl status syncthing@<your-username>
```

To find your username: `echo $USER`

---

## Issue 2 — Connection resets every 30–60 seconds

### Symptom

Syncthing connects to peer devices but disconnects and reconnects repeatedly at 30–60 second intervals. The GUI shows devices cycling between "Connected" and "Disconnected". No files transfer during this period.

### Root cause (one or more of the following)

**A) Syncthing bypassing Tailscale tunnel**
Syncthing's `dynamic` address mode probes multiple connection paths simultaneously — including direct UDP outside the Tailscale tunnel. Under symmetric NAT (CGNAT), these direct connection attempts fail, causing the session to reset.

**B) node_modules paths being synced**
Paths containing spaces inside `node_modules` (e.g., `node_modules/some package/file`) violate Syncthing's encrypted path format. When using `receiveencrypted`, these paths cause the relay to log errors and drop all connections — not just the affected file.

### Fix

**A) Pin device addresses to Tailscale IPs:**

In Syncthing GUI → Edit Device → Addresses, replace `dynamic` with:
```
quic://100.x.x.x:22000, tcp://100.x.x.x:22000
```
Do this for **every device** on **every node**. Use the device's Tailscale IP from `tailscale status`.

**B) Add ignore patterns to prevent node_modules from syncing:**

Place a `.stignore` file in the root of your synced folder containing:
```
**/node_modules
**/.git
**/.next
**/.nuxt
**/dist
**/build
**/.pnpm
```

After adding `.stignore`, restart Syncthing and allow a full rescan. See the `.stignore` template in the repo root.

---

## Issue 3 — API key not working

### Symptom

Scripts or `curl` calls to the Syncthing REST API return `403 Forbidden` or `401 Unauthorized` even with the correct API key from the config file. Example:

```bash
curl -H "X-API-Key: <your-key>" http://127.0.0.1:8384/rest/system/status
# Returns: 403
```

### Root cause

In **Syncthing v2.x**, the config file location changed:

| Version | Config path |
|---|---|
| v1.x (old stable) | `~/.local/share/syncthing/config.xml` |
| v2.x (candidate) | `~/.local/state/syncthing/config.xml` |

If you copied an API key from the old path, or if scripts are hardcoded to read from `~/.local/share/`, the key will be stale or from a different Syncthing instance.

### Fix

Always read the API key from the current config location:

```bash
# For Syncthing v2.x
grep -oP '(?<=<apikey>)[^<]+' ~/.local/state/syncthing/config.xml

# If unsure which version you have
syncthing --version

# Check both locations if necessary
ls -la ~/.local/share/syncthing/config.xml 2>/dev/null
ls -la ~/.local/state/syncthing/config.xml 2>/dev/null
```

Update any scripts that hardcode the old path.

---

## Issue 4 — Only one device can connect to the relay at a time

### Symptom

With two laptops and a relay node, only one laptop is ever shown as connected in the relay's Syncthing GUI. The second laptop shows as disconnected, even though it is online and reachable via Tailscale. Swapping which laptop is running causes the other to connect and the first to drop.

### Root cause

Syncthing's `connectionLimitMax` and `connectionLimitEnough` options both **default to 1**. When `connectionLimitEnough` is reached, Syncthing stops accepting new inbound connections — it considers itself "connected enough". With two laptop peers, the relay hits this limit after the first connection and refuses the second.

### Fix

Set both values to `0` (unlimited) in the relay's `config.xml`. The script `install-syncthing-pi.sh` does this automatically, but to apply manually:

```bash
# Stop Syncthing first
sudo systemctl stop syncthing@<your-username>

# Edit config
nano ~/.local/state/syncthing/config.xml

# Find the <options> section and set both values to 0:
# <connectionLimitEnough>0</connectionLimitEnough>
# <connectionLimitMax>0</connectionLimitMax>

# Restart
sudo systemctl start syncthing@<your-username>
```

Verify both laptops show as connected in the relay GUI within ~60 seconds.

---

## Issue 5 — "invalid encrypted path" crashes all connections

### Symptom

All peer connections drop simultaneously. The Syncthing log on the relay shows repeated errors like:

```
[RELAY] 2025/06/01 12:34:56 INFO: Puller (folder "XXXXX"): invalid encrypted path "node_modules/some package with spaces/index.js"
```

Even after removing the problem files, connections remain unstable.

### Root cause (two possible causes)

**A) node_modules (or other paths with spaces) are being synced**
The `receiveencrypted` protocol encodes filenames using a specific path format. Paths containing spaces — common inside `node_modules` — produce malformed encrypted path strings that cause the relay to abort the entire sync session, not just skip the file.

**B) Stale plaintext index entries after enabling encryption**
If the relay previously synced the folder in **normal (plaintext) mode** and was then switched to `receiveencrypted`, the old index (`index-v2.db`) contains plaintext path records. The v2.x encrypted protocol cannot reconcile these with the new encrypted blob format, causing persistent errors on every reconnect.

### Fix

**A) Add ignore patterns** (prevent the problem going forward):

Add a `.stignore` file to the synced folder root with:
```
**/node_modules
**/.git
**/.next
**/.nuxt
**/dist
**/build
**/.pnpm
```

**B) Wipe the stale index** (fix the historical corruption):

```bash
# On the relay node
sudo systemctl stop syncthing@<your-username>

# Wipe the index — Syncthing will rebuild it cleanly on next start
rm -rf ~/.local/state/syncthing/index-v2*

sudo systemctl start syncthing@<your-username>
```

⚠️ Wiping the index does **not** delete your synced files. It only removes Syncthing's internal database of what it thinks is synced. Syncthing will rescan and rebuild the index on startup — this may take a few minutes for large folders.

Apply **both fixes** together. Wiping the index without adding ignore patterns will reproduce the issue as soon as node_modules paths are encountered again.

---

## Issue 6 — Syncthing v1.x incompatible with v2.x encrypted folders

### Symptom

After setting up `receiveencrypted` on the relay, the laptops show the relay as connected but the folder never syncs. The relay's Syncthing log shows errors like:

```
[RELAY] protocol error: unknown message type or unsupported feature
```

Or the relay GUI shows the folder in an "Out of Sync" state with 0 bytes transferred.

### Root cause

The Debian `stable` apt channel for Syncthing is **pinned at v1.30.x**. The `receiveencrypted` folder type was introduced in **v2.0** with a new encrypted folder protocol. Syncthing v1.x cannot participate in an encrypted folder sync at all — the protocol is incompatible at the message level.

This is not a configuration issue. v1.x simply does not understand the v2.x sync protocol for encrypted folders.

### Fix

Switch the relay to the **candidate apt channel** and upgrade:

```bash
# Add the candidate channel (replaces or supplements stable)
curl -fsSL https://syncthing.net/release-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/syncthing-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] \
    https://apt.syncthing.net/ syncthing candidate" \
    | sudo tee /etc/apt/sources.list.d/syncthing.list

sudo apt-get update
sudo apt-get install -y syncthing

# Verify version
syncthing --version
# Expected: syncthing v2.1.1 or later
```

The `install-syncthing-pi.sh` script in this repo handles this automatically.

**Note:** The laptops (Windows) install Syncthing directly from syncthing.net — they are not subject to the Debian apt channel lag and receive v2.x by default.

---

## General Diagnostics

### Check service status on Pi
```bash
systemctl status syncthing@<your-username>
journalctl -u syncthing@<your-username> -n 50 --no-pager
```

### Access Syncthing GUI via SSH tunnel (Pi has no browser)
```bash
ssh -L 8384:127.0.0.1:8384 <your-username>@<tailscale-ip-of-relay>
# Then open http://127.0.0.1:8384 in your local browser
```

### Check Tailscale connectivity
```bash
tailscale status              # View all mesh nodes and their IPs
tailscale ping 100.x.x.x     # Test latency to a specific node
tailscale netcheck            # Check NAT type and DERP region selection
```

### Verify connection limits in config
```bash
grep -E "connectionLimit(Max|Enough)" ~/.local/state/syncthing/config.xml
# Expected: both values should be 0
```

### Verify Syncthing is only listening on Tailscale IPs
```bash
ss -tlnp | grep 22000
# Should show 100.x.x.x:22000, not 0.0.0.0:22000
```
