# PortRelay

A tiny, dependency-free "home-router port forwarding page" for **tailnet relay boxes**.

One bash script. Runs on any Linux machine that has `bash`, `ufw`, `iptables` and `tailscale`.
Point your domain at the relay's public IP, and forward anything to any machine in your tailnet.

```
players ──▶ relay box (this machine, public IP)
                │  DNAT + ufw route rules (managed by PortRelay)
                ▼  encrypted WireGuard (Tailscale)
            any tailnet machine:<port>   (game server, home lab, whatever)
```

## Install

On the machine that will do the forwarding (needs a public IP and a working `tailscale up`):

```bash
wget https://raw.githubusercontent.com/<you>/portrelay/main/portrelay.sh
chmod +x portrelay.sh
sudo ./portrelay.sh init      # first run: creates state dir + marker block in ufw
sudo ./portrelay.sh           # the router page
```

## The router page

```
╭──────────────────────────────────────────────────────────────╮
│ PortRelay  v0.1.0 — tailnet relay port forwards              │
╰──────────────────────────────────────────────────────────────╯

  ID   EN  IFACE      PROTO EPORT   DESTINATION
  1    ●   ens3       tcp   25565   gaming-pc(100.64.0.10):25565
  2    ●   ens3       udp   19132   gaming-pc(100.64.0.10):19132

  A dd  D elete  T oggle  L ive rules  R e-apply  Q uit
```

* **A** — wizard: pick interface (or any), external port, TCP/UDP/both,
  destination machine (**live from `tailscale status`**), destination port.
* **D** — delete · **T** — enable/disable · **L** — show live kernel + ufw rules
* **R** — re-apply from state file (repair)

## Scriptable too

```bash
sudo portrelay add ens3 25565 tcp 100.64.0.10 25565 gaming-pc
sudo portrelay add any  19132 udp gaming-pc   19132
sudo portrelay add ens3 2456  both valheim-box 2456
sudo portrelay list
sudo portrelay toggle 2
sudo portrelay remove 3
sudo portrelay status
```

## How it works (no magic)

State of truth is `/etc/portrelay/forwards.conf` (plain text, hand-editable).
Every change regenerates:

1. the DNAT rules inside the `# BEGIN/END PORTRELAY` block of `/etc/ufw/before.rules`
   (plus one always-on MASQUERADE line for the reply path), and
2. the matching `ufw route allow` rules

…then flushes the PREROUTING chain and does `ufw reload`. Each apply saves a
timestamped backup of `before.rules` (last 5 kept) and auto-restores it if
anything fails.

Remember the **third layer**: if this box is a cloud VM (Oracle, etc.), open the
same ports in the provider's firewall/security list — PortRelay only manages the
box itself.

## Uninstall

```bash
sudo portrelay remove-all      # clears forwards + rules
sudo rm /etc/portrelay -r      # remove state
sudo sed -i '/# BEGIN PORTRELAY/,/# END PORTRELAY/d' /etc/ufw/before.rules
sudo ufw reload                # (also remove the *nat skeleton if you added it)
```

## Notes & limits

* Destination IPs are resolved via `tailscale ip -4` at **add** time and stored,
  so rules never depend on DNS at runtime. If a machine's tailnet IP changes,
  re-add the forward.
* First relay on a fresh ufw install? Run `portrelay init` before anything else.
* One public port = one destination. Distinct external ports per service.
* Bedrock-style UDP services won't LAN-broadcast through a relay — add the
  server by `host:port`.

MIT licensed. Made with GLM-5.3-Flash (Z.ai), built and battle-tested on a live
Oracle Cloud Always Free relay by [wundervrc](https://github.com/wundervrc). :3
