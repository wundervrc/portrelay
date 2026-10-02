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
or you ban everyone at once. IP bans work again if you front the server with a proxy
that passes real client IPs, like proxy protocol or velocity forwarding (pumpkin has
a setting for the latter).

Give every public facing machine a tailscale tag and an ACL that blocks it from starting
connections to your other devices. It should receive traffic and accept your SSH. Nothing
else. The rules live in the tailscale admin console (login.tailscale.com), not on the
machines, so a hacked box cannot rewrite them.

## Uninstall

```bash
sudo portrelay remove-all
sudo rm -r /etc/portrelay
sudo sed -i '/# BEGIN PORTRELAY/,/# END PORTRELAY/d' /etc/ufw/before.rules
sudo ufw reload
```

MIT. Made with GLM 5.3 Flash. Tested on a real server by wundervrc.
