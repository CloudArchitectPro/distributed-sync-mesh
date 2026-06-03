# Architecture

This document describes the topology, data flow, networking model, and key design decisions of the Distributed File Sync Mesh.

---

## Node Topology

```
        US East                                US West
┌───────────────────────┐         ┌───────────────────────┐
│      node-us-east     │         │      node-us-west     │
│                       │         │                       │
│  OS:  Windows 10/11   │         │  OS:  Windows 10/11   │
│  App: Syncthing v2.x  │         │  App: Syncthing v2.x  │
│  VPN: Tailscale       │         │  VPN: Tailscale       │
│  IP:  100.x.x.1 *     │         │  IP:  100.x.x.2 *     │
│  Data: plaintext      │         │  Data: plaintext      │
└──────────┬────────────┘         └────────────┬──────────┘
           │                                   │
           │   WireGuard tunnel                │   WireGuard tunnel
           │   (Tailscale managed)             │   (Tailscale managed)
           │                                   │
           └─────────────────┬─────────────────┘
                             │
                  ┌──────────▼──────────┐
                  │    relay-node-in    │
                  │                     │
                  │  OS:  Debian 13     │
                  │  HW:  Raspberry Pi 5│
                  │  App: Syncthing v2.x│
                  │  VPN: Tailscale     │
                  │  IP:  100.x.x.3 *  │
                  │  Data: CIPHERTEXT   │  ← receiveencrypted
                  │  NAT:  CGNAT        │
                  └─────────────────────┘

* Replace with actual Tailscale IPs from: tailscale status
```

---

## Tailscale Mesh (WireGuard)

### What Tailscale provides

Each node in the mesh has a stable `100.x.x.x` address (Tailscale's managed subnet) regardless of the underlying ISP, NAT type, or physical location. This means:

- No port forwarding required anywhere
- No dynamic DNS or IP tracking
- All traffic is WireGuard-encrypted at the transport layer
- Device identity is verified via mutual certificate authentication (not just IP)

### Connection establishment

Tailscale uses a coordination server to bootstrap peer-to-peer WireGuard tunnels. For node pairs that can reach each other directly (e.g., both laptops on residential broadband), Tailscale establishes a direct WireGuard session. For the relay node, which sits behind CGNAT, Tailscale falls back to its DERP relay network.

```
Direct path (laptop ↔ laptop, when both online):
  node-us-east ──────────────────── node-us-west
               WireGuard direct P2P

CGNAT fallback (any node ↔ relay):
  node-us-east ── DERP relay server ── relay-node-in
                  (Tailscale-operated)
```

DERP fallback does **not** affect data integrity or encryption. The DERP relay sees only the WireGuard-encrypted payload — it cannot decrypt it.

---

## CGNAT Explained

### What is CGNAT?

Carrier-Grade NAT (CGNAT) is a network architecture where ISPs share a single public IP address across many residential customers. Unlike a home router's NAT (which gives you a private `192.168.x.x` address behind a single public IP), CGNAT adds a **second layer of NAT** between your router and the internet.

```
Internet
    │
    │  Public IP (shared across many customers)
    │
┌───▼──────────────────┐
│   ISP CGNAT device   │  ← carrier-operated, you have no access
└───┬──────────────────┘
    │  100.64.x.x address (RFC 6598 shared range)
    │
┌───▼──────────────────┐
│   Your home router   │
└───┬──────────────────┘
    │  192.168.x.x address
    │
┌───▼──────────────────┐
│   relay-node-in      │
└──────────────────────┘
```

### Why this breaks port forwarding

Port forwarding requires configuring your **public-facing router** to forward a port to an internal device. Under CGNAT, you don't control the public-facing device (the ISP's NAT box). Even if you forward port 22000 on your home router, the ISP's NAT does not forward it from the public internet to your router.

This is why `relay-node-in` cannot be reached by traditional Syncthing discovery or direct TCP connections.

### How Tailscale solves it

Tailscale uses **STUN-based NAT hole punching** for direct connections. When two peers are both behind NAT, Tailscale's coordination server helps them punch through by coordinating their external port mappings simultaneously.

When symmetric NAT (like CGNAT) prevents hole punching (`MappingVariesByDestIP: true` in Tailscale's diagnostic output), Tailscale automatically falls back to DERP relays. This is normal, expected, and handled transparently.

**To confirm your relay's NAT type:**
```bash
tailscale netcheck
# Look for: MappingVariesByDestIP: true  →  CGNAT confirmed, DERP will be used
```

---

## Syncthing Device Address Pinning

By default, Syncthing attempts to discover peer addresses via mDNS, global discovery, and direct UDP probing. On a Tailscale mesh, this can result in Syncthing trying connections outside the encrypted tunnel, which fail under CGNAT and cause periodic resets.

**Fix:** Pin every device's address to its Tailscale IP exclusively.

In Syncthing GUI → Edit Device → Addresses, replace `dynamic` with:

```
quic://100.x.x.x:22000, tcp://100.x.x.x:22000
```

Where `100.x.x.x` is the device's Tailscale IP (`tailscale status` to find it).

This forces all Syncthing traffic through the WireGuard tunnel. See [setup-windows.md](setup-windows.md) for the full Windows procedure.

---

## Data Flow: File Change to Full Sync

```
1. File saved on node-us-east
        │
        ▼
2. Syncthing watcher detects inotify/FSEvents change
        │
        ▼
3. Syncthing computes block-level delta (only changed blocks sent)
        │
        ▼
4. Delta encrypted by Syncthing TLS, tunneled through WireGuard
        │
        ▼
5. relay-node-in receives encrypted blob
   (cannot decrypt — receiveencrypted mode)
        │
        ▼
6. relay-node-in notifies node-us-west of new/updated blob
        │
        ▼
7. node-us-west pulls blob from relay over Tailscale tunnel
        │
        ▼
8. node-us-west decrypts and assembles file using folder password
        │
        ▼
9. All three nodes in sync — change propagated end-to-end
```

**If node-us-west is offline at step 6:** The blob sits on the relay. When node-us-west next connects, Syncthing's state machine detects the out-of-sync blocks and pulls them automatically. No manual intervention needed.

---

## Folder Type: `receiveencrypted`

Syncthing v2.x introduced `receiveencrypted` as a dedicated relay folder type. It differs from normal sync:

| Behavior | Normal folder | `receiveencrypted` folder |
|---|---|---|
| Stores plaintext | ✅ | ❌ |
| Stores encrypted blobs | ❌ | ✅ |
| Can modify/delete files | ✅ | ❌ (read-only relay) |
| Requires folder password | No | Set on sender nodes only |
| Visible filenames | ✅ | ❌ (encrypted) |

The relay cannot initiate deletions or overwrites of files on the laptop nodes. It is a **write-once encrypted store** from the perspective of the sync protocol.

---

## Versioning and Conflict Resolution

Syncthing handles conflicts automatically by creating conflict copies with timestamps in the filename:

```
document.txt                    ← winner (more recent mtime)
document.sync-conflict-20250601-143022-DEVICEID.txt  ← loser (kept for review)
```

For additional protection, enable **staggered versioning** on the laptop nodes:

Syncthing GUI → Edit Folder → File Versioning → Staggered File Versioning

Recommended settings: keep versions for 365 days, max age 365 days. The relay node does not need versioning configured — it stores blobs, not file history.

---

## Failure Modes

| Scenario | Behaviour |
|---|---|
| relay-node-in offline | Laptops detect no route; queue changes locally; resume automatically when relay returns |
| node-us-east offline | node-us-west and relay stay in sync with each other; east catches up on reconnect |
| Both laptops offline | Relay holds last-known encrypted state; resumes when either laptop reconnects |
| DERP relay congested | Tailscale switches DERP regions automatically; sync pauses briefly, then resumes |
| node_modules accidentally synced | "invalid encrypted path" errors crash all connections — see troubleshooting.md |
