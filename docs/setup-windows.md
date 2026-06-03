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

Syncthing should start automatically when you log in. The installer typically creates a scheduled task for this, but verify it exists:

### Check via Task Scheduler

1. Press `Win + R` → type `taskschd.msc` → Enter
2. In the left pane, click **Task Scheduler Library**
3. Look for a task named **"Start Syncthing at logon"** or similar
4. Confirm the **Actions** tab shows: `%LOCALAPPDATA%\Programs\Syncthing\stctl.exe --start`

### If the task is missing — create it manually

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

### Manual start/stop (for testing)

```powershell
# Start
& "$env:LOCALAPPDATA\Programs\Syncthing\stctl.exe" --start

# Stop
& "$env:LOCALAPPDATA\Programs\Syncthing\stctl.exe" --stop
```

---

## 3. Disable WiFi Adapter Power Management

Windows may power down the WiFi adapter after a period of inactivity to save battery. When this happens, the Tailscale WireGuard tunnel drops. Syncthing reconnects eventually, but the gap causes sync failures and the periodic disconnects described in troubleshooting Issue 2.

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
# List all adapters and their power management state
Get-NetAdapter | ForEach-Object {
    $name = $_.Name
    $pm = (Get-NetAdapterPowerManagement -Name $name -ErrorAction SilentlyContinue).AllowComputerToTurnOffDevice
    [PSCustomObject]@{ Adapter = $name; PowerOffAllowed = $pm }
}
# Expected: PowerOffAllowed = Disabled for your WiFi adapter
```

---

## 4. Pin Syncthing Device Addresses to Tailscale IPs

By default, Syncthing uses `dynamic` address discovery, which includes mDNS and global discovery probes outside the Tailscale tunnel. Under the CGNAT configuration of the relay node, these discovery attempts fail and cause connection resets.

Pin every peer device's address to its Tailscale IP to force all traffic through the encrypted tunnel.

### Find Tailscale IPs

```powershell
# On each machine, run:
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
   Where `100.x.x.x` is that device's Tailscale IP.
4. Click **Save**

Repeat this on **both laptop nodes** for **all peer devices** (the relay and the other laptop).

### Example — `node-us-east` configuration

| Device | Address field |
|---|---|
| relay-node-in | `quic://100.x.x.3:22000, tcp://100.x.x.3:22000` |
| node-us-west | `quic://100.x.x.2:22000, tcp://100.x.x.2:22000` |

Replace `100.x.x.x` with actual Tailscale IPs from `tailscale status`.

---

## 5. Set the Folder Encryption Password

Both laptop nodes must use the **same folder encryption password** so they can decrypt files pulled from the relay.

1. Syncthing GUI → Click the shared folder → **Edit**
2. Click the **Sharing** tab
3. Find the relay device (`relay-node-in`) in the device list
4. Enter the same **Encryption Password** on both laptop nodes
5. Click **Save**, then **Restart** Syncthing when prompted

> ⚠️ The relay node does **not** have an encryption password — it stores encrypted blobs without knowing the key. Set the password only on the laptop nodes.

---

## 6. Place `.stignore` in the Sync Folder

Copy the `.stignore` file from this repo into the root of your synced folder **before** Syncthing scans it for the first time. Without it, any `node_modules` directory in the folder will cause "invalid encrypted path" errors that crash all connections (see troubleshooting Issue 5).

```powershell
# Example — adjust path to match your sync folder location
Copy-Item "path\to\distributed-sync-mesh\.stignore" "C:\Users\<username>\Sync\.stignore"
```

If Syncthing has already scanned and synced `node_modules`, add the `.stignore` file, then in Syncthing GUI: Edit Folder → **Rescan**. Files already synced will not be removed from peers; they will simply stop being tracked going forward.

---

## 7. Verify the Setup

Run through this checklist after completing all steps:

```powershell
# 1. Tailscale mesh is up
tailscale status
# Expected: relay-node-in and the other laptop both show as connected (green)

# 2. Syncthing GUI loads
Start-Process "http://127.0.0.1:8384"
# Expected: GUI opens; all devices show as Connected

# 3. No dynamic addresses remain
# In Syncthing GUI, check each device's address field — none should say "dynamic"

# 4. Service is running and will survive reboot
Get-ScheduledTask -TaskName "Start Syncthing at logon" | Select-Object TaskName, State
# Expected: State = Ready

# 5. WiFi adapter will not be powered off
Get-NetAdapterPowerManagement -Name "Wi-Fi" | Select-Object AllowComputerToTurnOffDevice
# Expected: Disabled
```

---

## Config File Location (Windows)

If you need to inspect or back up the Syncthing config on Windows:

```
%LOCALAPPDATA%\Syncthing\config.xml
```

The API key is in this file under `<apikey>`. Never commit this file to a public repository.

To open the folder in Explorer:

```powershell
explorer "$env:LOCALAPPDATA\Syncthing"
```
