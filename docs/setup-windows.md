# Windows Node Setup

This guide covers setup for `node-us-east` and `node-us-west` — the Windows laptop endpoints. Follow every section; skipping WiFi power management, for example, causes intermittent Tailscale tunnel drops that are hard to diagnose.

---

## Prerequisites

- Windows 10 or 11
- Tailscale installed and authenticated (`tailscale status` shows your node)
- Syncthing downloaded from [syncthing.net](https://syncthing.net/downloads/) — this installs the full package including `stctl.exe`

---

## 1. Install Syncthing

Download the Windows installer from [syncthing.net/downloads](https://syncthing.net/downloads/). The installer places files at:

```
%LOCALAPPDATA%\Programs\Syncthing\
├── syncthing.exe     ← core sync daemon
└── stctl.exe         ← system tray controller (use this, not syncthing.exe directly)
```

**Important:** Launch Syncthing using `stctl.exe`, not `syncthing.exe`. `stctl.exe` manages the tray icon, graceful shutdown, and start/stop without requiring a separate service. Launching `syncthing.exe` directly bypasses the tray controller and may create orphaned processes.

---

## 2. Configure Autostart at Login

Syncthing should start automatically when you log in. The installer typically creates a scheduled task for this, but verify it exists.

### Check via Task Scheduler

1. Press `Win + R` → type `taskschd.msc` → Enter
2. In the left pane, click **Task Scheduler Library**
3. Look for a task named **"Start Syncthing at logon"** or similar
4. Confirm the **Actions** tab shows: `%LOCALAPPDATA%\Programs\Syncthing\stctl.exe --start`

### Check via PowerShell

```powershell
# Confirm scheduled task exists
Get-ScheduledTask -TaskName "Start Syncthing at logon" | Select-Object TaskName, State
# Expected: State = Ready

# Confirm Syncthing process is running
Get-Process syncthing -ErrorAction SilentlyContinue
# Expected: two processes (launcher + main daemon)

# Confirm no startup shortcut conflict exists
Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Syncthing.lnk"
# Expected: False — startup shortcut and scheduled task running simultaneously causes duplicate processes
```

### If the scheduled task is missing — create it

Open PowerShell as Administrator:

```powershell
$action = New-ScheduledTaskAction `
    -Execute "$env:LOCALAPPDATA\Programs\Syncthing\stctl.exe" `
    -Argument "--start"

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit 0

Register-ScheduledTask `
    -TaskName "Start Syncthing at logon" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Limited `
    -Force
```

### If you previously created a startup shortcut instead

The startup shortcut method (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Syncthing.lnk`)
works but bypasses `stctl.exe` and the system tray. If you used this method,
remove the shortcut and replace with the scheduled task above:

```powershell
# Remove startup shortcut if present
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Syncthing.lnk" -ErrorAction SilentlyContinue

# Then create the scheduled task using the block above
```

### Manual start/stop (for testing)

```powershell
# Start
& "$env:LOCALAPPDATA\Programs\Syncthing\stctl.exe" --start

# Stop
& "$env:LOCALAPPDATA\Programs\Syncthing\stctl.exe" --stop
```

---

## 3. Disable WiFi Adapter Power Management

Windows may power down the WiFi adapter after a period of inactivity to save
battery. When this happens, the Tailscale WireGuard tunnel drops. Syncthing
reconnects eventually, but the gap causes sync failures and the periodic
disconnects described in troubleshooting Issue 2.

This setting must be changed for **every WiFi adapter** on each laptop.

### Steps

1. Press `Win + X` → **Device Manager**
2. Expand **Network Adapters**
3. Right-click your WiFi adapter (e.g., "Intel Wi-Fi 6 AX201") → **Properties**
4. Click the **Power Management** tab
5. **Uncheck** "Allow the computer to turn off this device to save power"
6. Click **OK**

Repeat for any additional network adapters (e.g., Ethernet, Bluetooth adapter if shown).

### Verify via PowerShell

```powershell
Get-NetAdapter | ForEach-Object {
    $name = $_.Name
    $pm = (Get-NetAdapterPowerManagement -Name $name -ErrorAction SilentlyContinue).AllowComputerToTurnOffDevice
    [PSCustomObject]@{ Adapter = $name; PowerOffAllowed = $pm }
}
# Expected: PowerOffAllowed = Disabled for your WiFi adapter
```

---

## 4. Pin Syncthing Device Addresses to Tailscale IPs

By default, Syncthing uses `dynamic` address discovery, which includes mDNS
and global discovery probes outside the Tailscale tunnel. Under the CGNAT
configuration of the relay node, these discovery attempts fail and cause
connection resets.

Pin every peer device's address to its Tailscale IP to force all traffic
through the encrypted tunnel.

### Find Tailscale IPs

```powershell
tailscale status
# Note the 100.x.x.x IP for each node
```

### Apply pinning in Syncthing GUI

1. Open Syncthing GUI: `http://127.0.0.1:8384`
2. For **each peer device** (click the device → **Edit**):
3. In the **Addresses** field, replace `dynamic` with:
   ```
   quic://100.x.x.x:22000, tcp://100.x.x.x:22000
   ```
4. Click **Save**

Repeat on **both laptop nodes** for **all peer devices**.

### Node Tailscale IPs (this mesh)

| Node | Tailscale IP | Address field |
|---|---|---|
| `relay-node-in` | `100.127.52.60` | `quic://100.127.52.60:22000, tcp://100.127.52.60:22000` |
| `node-us-east` | `100.67.74.77` | `quic://100.67.74.77:22000, tcp://100.67.74.77:22000` |
| `node-us-west` | `100.104.175.22` | `quic://100.104.175.22:22000, tcp://100.104.175.22:22000` |

---

## 5. Set the Folder Encryption Password

Both laptop nodes must use the **same folder encryption password** so they can
decrypt files pulled from the relay.

1. Syncthing GUI → Click the shared folder → **Edit**
2. Click the **Sharing** tab
3. Find `relay-node-in` in the device list
4. Enter the **Encryption Password** — must match on both laptops
5. Click **Save**, then **Restart** Syncthing when prompted

> ⚠️ The relay node does **not** have an encryption password — it stores
> encrypted blobs without knowing the key. Set the password only on the
> laptop nodes.

---

## 6. Place `.stignore` in the Sync Folder

Copy the `.stignore` file from this repo into the root of your synced folder
**before** Syncthing scans it for the first time. Without it, any
`node_modules` directory in the folder will cause "invalid encrypted path"
errors that crash all connections (see troubleshooting Issue 5).

```powershell
Copy-Item "path\to\distributed-sync-mesh\.stignore" "C:\Users\<username>\Sync\.stignore"
```

If Syncthing has already scanned and synced `node_modules`, add the
`.stignore` file, then in Syncthing GUI: Edit Folder → **Rescan**.

---

## 7. Initial Sync Expectations

The first sync of ~19.6 GiB across 172,000+ files takes time. What to expect:

| Phase | What you see | Normal? |
|---|---|---|
| Indexing | High CPU, folder shows "Scanning" | ✅ Yes |
| Syncing | Gradual % progress, "Syncing (X%, Y MiB)" | ✅ Yes |
| Relay writing | High iowait on Pi (SD card saturation) | ✅ Yes — one-time only |
| "Waiting to Sync" | Folder paused waiting for peer | ✅ Yes — resolves automatically |
| "no connected device has the required version" | Transient — peer went offline mid-sync | ✅ Yes — resolves on reconnect |

After initial sync completes, incremental syncs are near-instant (< 30 seconds
end-to-end) and the relay uses < 2% CPU at idle.

**Do not interrupt the initial sync.** Both laptops and the Pi can go offline
independently — Syncthing resumes automatically from where it left off.

---

## 8. Verify the Full Setup

```powershell
# 1. Tailscale mesh is up
tailscale status

# 2. Syncthing is running
Get-Process syncthing -ErrorAction SilentlyContinue

# 3. Autostart scheduled task is ready
Get-ScheduledTask -TaskName "Start Syncthing at logon" | Select-Object TaskName, State

# 4. WiFi adapter power management is disabled
Get-NetAdapterPowerManagement -Name "Wi-Fi" | Select-Object AllowComputerToTurnOffDevice
# Expected: Disabled

# 5. Syncthing GUI is reachable
Start-Process "http://127.0.0.1:8384"
# Confirm: all devices show Connected, no devices show "dynamic" address
```

---

## Config File Location (Windows)

```
%LOCALAPPDATA%\Syncthing\config.xml
```

The API key is in this file under `<apikey>`. Never commit this file to a
public repository.

```powershell
explorer "$env:LOCALAPPDATA\Syncthing"
```

---

## Device Naming Reference

Syncthing device labels are cosmetic and do not affect sync. The canonical
names for this mesh are:

| Syncthing label | Device | Old name (if migrating) |
|---|---|---|
| `relay-node-in` | Raspberry Pi 5 · India | — |
| `node-us-east` | Laptop 1 · Windows (`Naveen`) | Clouma |
| `node-us-west` | Laptop 2 · Windows (`hpspe`) | Soul |

To rename a device: Syncthing GUI → click the device → **Edit** → update
the **Name** field → **Save**. Device ID is unchanged.

---

*Last updated: June 2026 — Syncthing v2.1.1, Windows 10/11, Tailscale, relay-node-in on Raspberry Pi 5 · Debian 13*
