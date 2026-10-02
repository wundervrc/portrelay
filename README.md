# PortRelay

Forward ports from this machine to any machine in your tailnet. One bash script, no dependencies.

Players connect to this machine. Traffic rides tailscale to whatever machine you pick.

## Install

On the machine with the public IP:

```bash
wget https://raw.githubusercontent.com/wundervrc/portrelay/main/portrelay.sh
chmod +x portrelay.sh
sudo ./portrelay.sh init
sudo ./portrelay.sh
```

## Router page

```
╭──────────────────────────────────────────────────────────────╮
│ PortRelay  v0.1.0, tailnet relay port forwards               │
╰──────────────────────────────────────────────────────────────╯

  ID   EN  IFACE      PROTO EPORT   DESTINATION
  1    ●   ens3       tcp   25565   gaming-pc(100.64.0.10):25565
  2    ●   ens3       udp   19132   gaming-pc(100.64.0.10):19132

  A dd  D elete  T oggle  L ive rules  R e-apply  Q uit
```

## Or commands

```bash
sudo portrelay add ens3 25565 both 100.64.0.10 25565 gaming-pc
sudo portrelay list
sudo portrelay toggle 2
sudo portrelay remove 3
sudo portrelay status
```

## How it works

Your rules live in /etc/portrelay/forwards.conf. PortRelay turns them into DNAT rules
and ufw route rules, then reloads ufw. That is the whole trick. It also saves a copy of
the firewall file before every change, in /etc/portrelay/backups.

Open the same ports in your provider firewall too. PortRelay only manages this machine.

## Precautions

All players share this machine's IP once forwarded. Ban by player name, never by IP,
or you ban everyone at once. IP bans work again if you front the game server with a
proxy that passes real client IPs, like proxy protocol or velocity style forwarding.

Give every public facing machine a tailscale tag and an ACL that blocks it from starting
connections to your other devices. It should receive traffic and accept your SSH. Nothing
else. The rules live in the tailscale admin console (login.tailscale.com).

## Uninstall

```bash
sudo portrelay remove-all
sudo rm -r /etc/portrelay
sudo sed -i '/# BEGIN PORTRELAY/,/# END PORTRELAY/d' /etc/ufw/before.rules
sudo ufw reload
```

## My setup: a free Oracle Cloud relay

This is the exact recipe I use. A free Oracle VPS is the relay for any machines I want accessible over the web

1. Sign up at oracle.com/cloud/free. Pick the home region closest to you, it can never be
   changed. A card is required. Oracle puts a temporary hold on it (mine was 130 CAD) and
   refunds it automatically.
2. Wait for the account ready email, then upgrade to Pay As You Go. This stops Oracle
   from stopping idle free VMs. Everything within the Always Free limits stays 0 dollars.
3. Add a budget alert under Billing, Budgets. If anything ever bills you get an email
   instead of a surprise (ie someone hacks your Oracle account).
4. Create instance. Shape with the Always Free badge, capacity type On demand, image
   Ubuntu LTS, let it create the VCN, add your SSH public key.
5. Networking: reserve a public IP, then apply that reserved IP to your VNIC. It survives
   stop and start, so your DNS record never goes stale.
6. In the VCN security list, add ingress rules for your game ports, for example TCP 25565
   and UDP 19132 from 0.0.0.0/0. Leave the source port range empty.
7. SSH in and strip the firewall rules Oracle ships with Ubuntu:
   `apt purge netfilter-persistent iptables-persistent`, delete /etc/iptables/rules.v4,
   flush iptables, reboot.
8. Install tailscale, run `tailscale up`, install ufw and allow SSH only on tailscale0.
   Tag the machine(s) in the admin console so they can not SSH into your tailnet devices.
   I tagged both the VPS and the game servers players connect to, so I can SSH in but
   they can not SSH out. One caveat: tags and ACLs only govern tailnet traffic. A pwned
   box can still attack its own physical LAN, so put public facing machines on their own
   VLAN if you can.
9. Install PortRelay (init, then the router page) and forward your game ports.

Destination machines do not even need tailscale. Any IP the relay can reach works, pick
the custom IP option in the wizard. I run tailscale on all of mine anyway: machine names,
static tailscale IPs and ACLs are all very valuable to me.

MIT. Made with GLM 5.3 Flash. Built and tested by wundervrc, first tested with a
Minecraft (Pumpkin) game server.
