# Security Model

This document covers the threat model, encryption architecture, and incident response procedures for the Distributed File Sync Mesh.

---

## Threat Model

| Threat | Likelihood | Mitigation |
|---|---|---|
| Network interception (MITM) | Low | WireGuard (Tailscale) + TLS (Syncthing) — double-encrypted in transit |
| Relay node physically stolen | Medium | `receiveencrypted` — relay stores ciphertext only; no folder password = no data |
| Relay node remotely compromised | Low | Zero open ports; Syncthing GUI bound to `127.0.0.1`; no SSH password auth |
| Laptop lost or stolen | Medium | Data at rest on laptop is not encrypted by this system — use OS-level encryption (BitLocker) |
| Syncthing API key leaked | Low | API key grants full Syncthing control on that node only; rotate immediately if exposed |
| Tailscale account compromised | Low | Revoke node keys from Tailscale admin console; all mesh access is immediately severed |
| Accidental mass deletion | Medium | Enable staggered versioning on laptop nodes; `receiveencrypted` relay cannot delete originals |

### Out of scope

- Encryption of data **on the laptops themselves** — use BitLocker or VeraCrypt for full-disk encryption
- Protection against a malicious insider who has the folder password and physical access to a laptop
- DDoS or availability attacks — this is a personal sync mesh, not a public service

---

## Encryption Architecture

### In transit

All Syncthing traffic is routed exclusively through Tailscale's WireGuard mesh. This means every byte is encrypted twice:

1. **Syncthing TLS** — application-layer encryption between Syncthing peers
2. **WireGuard** — transport-layer encryption enforced by Tailscale

No Syncthing traffic is permitted outside the Tailscale tunnel. Device addresses are pinned to `100.x.x.x` Tailscale IPs (see [setup-windows.md](docs/setup-windows.md)).

### At rest on the relay (`receiveencrypted`)

The relay node uses Syncthing's `receiveencrypted` folder type. This means:

- Files are stored as **AES-SIV encrypted blobs** — the relay never sees plaintext
- The folder password is set on the **laptop nodes only** and never transmitted to the relay
- The relay can sync, store, and forward data without ever being able to read it
- Filenames are also encrypted — directory listings on the relay reveal nothing about content

**The relay is treated as an untrusted intermediary by design.** It is assumed to be potentially compromised at all times.

### What the relay operator can see

| What | Visible to relay? |
|---|---|
| File contents | ❌ No — AES-SIV encrypted |
| Filenames | ❌ No — encrypted in blob metadata |
| File sizes (approximate) | ⚠️ Yes — blob sizes are visible |
| Sync activity timing | ⚠️ Yes — connection timestamps are logged |
| Number of files | ⚠️ Yes — blob count is visible |

---

## If the Relay Node Is Stolen

### Immediate steps

1. **Revoke Tailscale access** — log in to [login.tailscale.com](https://login.tailscale.com), go to **Machines**, find `relay-node-01`, and click **Remove**. This immediately cuts all mesh access from that device.

2. **Remove the device from Syncthing** — on both laptops, open Syncthing GUI (`http://127.0.0.1:8384`), go to **Devices**, select `relay-node-01`, and click **Remove**. Syncthing will stop attempting to connect.

3. **Assess data exposure** — because the relay uses `receiveencrypted`, the stolen SD card contains only ciphertext. Without the folder password (which only exists on your laptops), the data is computationally unreadable. **No plaintext data was exposed.**

4. **Rotate the folder password (optional but recommended)** — if you want to be certain forward secrecy is maintained:
   - On both laptops, edit the shared folder in Syncthing GUI
   - Change the **Encryption Password** under the folder sharing settings
   - Re-share the folder to the new relay node with the new password
   - The relay will re-receive all files encrypted under the new key

5. **Provision a replacement relay** — re-run `install-syncthing-pi.sh` on a new Pi, then re-add it to both laptops via Syncthing and Tailscale.

### What an attacker gets from the stolen SD card

```
/home/<username>/.local/state/syncthing/
├── index-v2.db          ← Syncthing internal index (no plaintext filenames)
└── ...

<sync-folder>/
├── .stfolder            ← Marker file only
├── <encrypted-blob-1>   ← AES-SIV ciphertext, unreadable
├── <encrypted-blob-2>   ← AES-SIV ciphertext, unreadable
└── ...
```

**Bottom line: a stolen relay SD card is a brick without the folder password.**

---

## If a Laptop Is Stolen

The laptop stores plaintext data. Steps:

1. **Remove it from Tailscale** — revoke the machine key in the Tailscale admin console
2. **Remove it from Syncthing** — on the remaining laptop, remove the stolen device from Syncthing
3. **Rotate the Syncthing folder password** — the stolen laptop held the encryption key for the relay; rotate it as described above
4. **Enable BitLocker** on your remaining laptop if not already active — data at rest on laptops is outside this system's encryption scope

---

## SSH Hardening (Relay Node)

The relay should be configured with key-only SSH authentication:

```bash
# /etc/ssh/sshd_config — required settings
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
```

After placing your public key in `~/.ssh/authorized_keys`:

```bash
sudo systemctl restart sshd
```

Test key-based login before closing your session.

---

## Syncthing API Key

The Syncthing API key is stored in `config.xml` under `<apikey>`. It grants full control of that Syncthing instance.

- Never commit `config.xml` to a public repository
- If exposed, generate a new key: Syncthing GUI → **Actions** → **Advanced** → regenerate API key, then restart Syncthing
- The `config/pi-config-template.xml` in this repo uses `YOUR_API_KEY` as a placeholder — it contains no real credentials

---

## Tailscale ACL Recommendations

By default, all Tailscale nodes can reach each other on all ports. For a tighter posture, apply an ACL in the Tailscale admin console that allows only port 22000 (Syncthing sync) and 22 (SSH) between mesh nodes:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:sync-node"],
      "dst": ["tag:sync-node:22,22000"]
    }
  ]
}
```

Tag each machine as `sync-node` in the Tailscale admin console to apply this policy.
