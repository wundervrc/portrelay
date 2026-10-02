#!/usr/bin/env bash
# ============================================================================
#  PortRelay — a tiny "home-router page" for tailnet relay boxes.
#
#  What it does
#    Manages port-forwarding rules on THIS machine (the relay):
#        <internet> -> this machine:<port>/<proto>  -->  <tailnet machine>:<port>
#    by keeping ONE place of truth (a small state file), and generating:
#      - DNAT rules in the *nat section of /etc/ufw/before.rules
#        (between "# BEGIN PORTRELAY" / "# END PORTRELAY" markers)
#      - matching `ufw route allow` rules for the forward path
#    then reloading ufw. Nothing else is touched.
#
#  Requirements (all standard): bash, ufw, iptables, tailscale, root via sudo.
#  Install:   wget <url> -O portrelay.sh && chmod +x portrelay.sh && ./portrelay.sh
#  Uninstall: portrelay remove-all, then delete the marked block + state dir.
#
#  Usage:
#    portrelay                 interactive TUI (the "router page")
#    portrelay init            first-run: create state dir + marker block
#    portrelay add <iface|any> <extport> <tcp|udp|both> <dest> <dport> [name]
#    portrelay remove <id>     delete a forward
#    portrelay toggle <id>     enable/disable a forward
#    portrelay list            show forwards
#    portrelay status          state + live kernel rules
#    portrelay apply           re-generate everything from the state file
#
#  State file format (one forward per line, pipe-separated):
#    id|enabled(y/n)|iface|proto|extport|dest_name|dest_ip|dest_port
#
#  Notes:
#    - Destination IPs are resolved with `tailscale ip -4` at ADD time and
#      stored, so rules never depend on DNS at runtime. If a machine's
#      tailnet IP ever changes, re-add the forward (30 seconds).
#    - "both" (TCP+UDP) simply creates two records that live and die together.
# ============================================================================

VERSION="0.1.0"
STATE_DIR="/etc/portrelay"
STATE_FILE="$STATE_DIR/forwards.conf"
BACKUP_DIR="$STATE_DIR/backups"
UFW_FILE="/etc/ufw/before.rules"
MARK_BEGIN="# BEGIN PORTRELAY"
MARK_END="# END PORTRELAY"
MASQ_LINE="-A POSTROUTING -o tailscale0 -j MASQUERADE"

# ---------------------------------------------------------------- colors ----
if [[ -t 1 ]]; then
    C_R=$'\e[0m' C_G=$'\e[1;32m' C_Y=$'\e[1;33m' C_B=$'\e[1;36m' C_DIM=$'\e[2m'
else
    C_R="" C_G="" C_Y="" C_B="" C_DIM=""
fi

die()   { echo "portrelay: ${C_Y}$*${C_R}" >&2; exit 1; }
pause() { echo; read -r -p "$* [Enter] " _; }
need_root() { [[ $(id -u) -eq 0 ]] || exec sudo -- "$0" "$@"; }

check_env() {
    local miss=0
    for c in ufw iptables tailscale; do
        command -v "$c" >/dev/null || { echo "missing: $c"; miss=1; }
    done
    [[ -f $UFW_FILE ]] || { echo "missing: $UFW_FILE (is ufw installed?)"; miss=1; }
    (( miss )) && die "environment check failed"
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }

# ---------------------------------------------------------------- state -----
load_state() {
    FORWARDS=()
    [[ -f $STATE_FILE ]] || return 0
    local line
    while IFS= read -r line; do
        [[ -n $line ]] && FORWARDS+=("$line")
    done < "$STATE_FILE"
}

save_state() {
    mkdir -p "$STATE_DIR"
    : > "$STATE_FILE"
    local f
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] && echo "$f" >> "$STATE_FILE"
    done
}

next_id() {
    local max=0 f id
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] || continue
        id=${f%%|*}
        (( 10#$id > max )) && max=10#$id
    done
    echo $((max + 1))
}

# fields: 0=id 1=en 2=iface 3=proto 4=extport 5=destname 6=destip 7=dport
field() { cut -d'|' -f"$(($2 + 1))" <<< "$1"; }

# ------------------------------------------------- tailscale machine list ---
ts_machines() {
    # prints "IP  hostname" for every machine in the tailnet (incl. self)
    tailscale status 2>/dev/null | awk 'NF>=2 {print $2"  "$1}'
}

resolve_dest() { # $1 = name or IP -> echoes IPv4
    if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$1"
    else
        tailscale ip -4 "$1" 2>/dev/null || die "cannot resolve '$1' via tailscale"
    fi
}

# ------------------------------------------------------------ generation ----
gen_block() {
    # the always-needed masquerade so reply traffic finds its way back
    echo "$MASQ_LINE"
    local f en iface proto ext dname dip dport p iface_part
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] || continue
        en=$(field "$f" 1); [[ $en == y ]] || continue
        iface=$(field "$f" 2); proto=$(field "$f" 3)
        ext=$(field "$f" 4); dip=$(field "$f" 6); dport=$(field "$f" 7)
        iface_part=""
        [[ $iface != any ]] && iface_part="-i $iface "
        for p in $proto; do
            echo "-A PREROUTING $iface_part-p $p --dport $ext -j DNAT --to-destination $dip:$dport"
        done
    done
}

ufw_rule_text() { # $1 = record -> the exact `ufw route ...` argument string
    local id=$(field "$1" 0) iface=$(field "$1" 2) proto=$(field "$1" 3)
    local ext=$(field "$1" 4) dip=$(field "$1" 6) dport=$(field "$1" 7)
    local in_part=""
    [[ $iface != any ]] && in_part="in on $iface "
    echo "$in_part out on tailscale0 proto $proto to $dip port $dport comment portrelay:$id"
}

apply() {
    [[ -f $STATE_FILE ]] || die "no state file — run 'portrelay init' first"
    if ! grep -qF "$MARK_BEGIN" "$UFW_FILE"; then
        die "no $MARK_BEGIN markers in $UFW_FILE — run 'portrelay init' (or migrate manually, see README)"
    fi

    # 1) backup before.rules (keep last 5)
    mkdir -p "$BACKUP_DIR"
    local bak="$BACKUP_DIR/before.rules.$(date +%Y%m%d-%H%M%S)"
    cp -p "$UFW_FILE" "$bak"
    ls -1t "$BACKUP_DIR"/before.rules.* 2>/dev/null | tail -n +6 | xargs -r rm -f

    # 2) rewrite the marked block
    local blockfile blocktmp
    blockfile=$(mktemp); blocktmp=$(mktemp)
    gen_block > "$blockfile"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v bf="$blockfile" '
        $0 == b { inb = 1; print b;
                  while ((getline l < bf) > 0) print l; close(bf); next }
        inb && $0 == e { inb = 0; print e; next }
        !inb { print }
    ' "$UFW_FILE" > "$blocktmp"
    rm -f "$blockfile"

    # sanity: file must still contain both tables and a COMMIT
    grep -q '^\*nat'      "$blocktmp" || { rm -f "$blocktmp"; restore "$bak"; die "sanity check failed (*nat)"; }
    grep -q '^\*filter'   "$blocktmp" || { rm -f "$blocktmp"; restore "$bak"; die "sanity check failed (*filter)"; }
    grep -q '^COMMIT'     "$blocktmp" || { rm -f "$blocktmp"; restore "$bak"; die "sanity check failed (COMMIT)"; }
    cp "$blocktmp" "$UFW_FILE"; rm -f "$blocktmp"

    # 3) sync ufw route rules to match state (delete all known, re-add enabled)
    local f rt
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] || continue
        rt=$(ufw_rule_text "$f")
        ufw route delete allow $rt >/dev/null 2>&1 || true
        if [[ $(field "$f" 1) == y ]]; then
            ufw route allow $rt >/dev/null || { restore "$bak"; die "ufw route allow failed"; }
        fi
    done

    # 4) flush PREROUTING (ufw reload does not always clean stale nat rules)
    #    then reload so before.rules is re-applied atomically
    iptables -t nat -F PREROUTING
    ufw reload >/dev/null || { restore "$bak"; die "ufw reload failed"; }

    echo "${C_G}applied.${C_R} (backup: $bak)"
}

restore() { cp -p "$1" "$UFW_FILE"; ufw reload >/dev/null 2>&1 || true; echo "${C_Y}restored previous firewall config${C_R}" >&2; }

# ---------------------------------------------------------------- init ------
cmd_init() {
    mkdir -p "$STATE_DIR"
    [[ -f $STATE_FILE ]] || : > "$STATE_FILE"
    if grep -qF "$MARK_BEGIN" "$UFW_FILE"; then
        echo "markers already present — nothing to do"
    elif grep -q '^\*nat' "$UFW_FILE"; then
        die "$UFW_FILE already has a *nat section without portrelay markers.
Migrate manually (wrap your -A lines in $MARK_BEGIN/$MARK_END, keep *nat/:lines/COMMIT), then re-run apply."
    else
        local skel tmp
        skel=$(mktemp); tmp=$(mktemp)
        cat > "$skel" <<SKEL
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
$MARK_BEGIN
$MASQ_LINE
$MARK_END
COMMIT

SKEL
        awk -v sk="$skel" 'BEGIN{done=0}
            !done && /^\*filter/ { while ((getline l < sk) > 0) print l; close(sk); done=1 }
            { print }
        ' "$UFW_FILE" > "$tmp"
        rm -f "$skel"
        cp "$tmp" "$UFW_FILE"; rm -f "$tmp"
        ufw reload >/dev/null
        echo "initialized: state dir + marker block created"
    fi
}

# ------------------------------------------------------------ commands ------
cmd_add() {
    local iface=$1 ext=$2 proto=$3 dest=$4 dport=$5 name=${6:-}
    [[ $iface == any ]] || ip link show "$iface" >/dev/null 2>&1 || die "no such interface: $iface"
    valid_port "$ext"  || die "bad external port: $ext"
    valid_port "$dport" || die "bad destination port: $dport"
    case $proto in tcp|udp|both) ;; *) die "proto must be tcp, udp, or both";; esac
    local dip; dip=$(resolve_dest "$dest")
    [[ -n $name ]] || name=$dest
    local protos="$proto"; [[ $proto == both ]] && protos="tcp udp"
    local p
    for p in $protos; do
        local id; id=$(next_id)
        FORWARDS+=("$id|y|$iface|$p|$ext|$name|$dip|$dport")
    done
    save_state; apply
    echo "forward(s) added: $iface:$ext/$proto -> $name ($dip):$dport"
}

cmd_remove() {
    local id=$1 f out=() removed=""
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] || continue
        if [[ ${f%%|*} == "$id" ]]; then
            removed="$f"
            ufw route delete allow $(ufw_rule_text "$f") >/dev/null 2>&1 || true
        else
            out+=("$f")
        fi
    done
    [[ -n $removed ]] || die "no forward #$id"
    FORWARDS=("${out[@]:-}"); save_state; apply
    echo "removed: $removed"
}

cmd_toggle() {
    local id=$1 f out=() found=0
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] || continue
        if [[ ${f%%|*} == "$id" ]]; then
            found=1
            local en=$(field "$f" 1)
            if [[ $en == y ]]; then f=${f/|y|/|n|}; else f=${f/|n|/|y|}; fi
        fi
        out+=("$f")
    done
    (( found )) || die "no forward #$id"
    FORWARDS=("${out[@]}"); save_state; apply
}

cmd_list() {
    if [[ ${#FORWARDS[@]} -eq 0 ]]; then echo "no forwards"; return 0; fi
    printf "%-4s %-3s %-10s %-5s %-7s %s\n" ID EN IFACE PROTO EPORT "DESTINATION"
    local f
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] || continue
        printf "%-4s %-3s %-10s %-5s %-7s %s(%s):%s\n" \
            "$(field "$f" 0)" "$(field "$f" 1)" "$(field "$f" 2)" \
            "$(field "$f" 3)" "$(field "$f" 4)" \
            "$(field "$f" 5)" "$(field "$f" 6)" "$(field "$f" 7)"
    done
}

cmd_status() {
    cmd_list
    echo; echo "${C_DIM}-- live nat PREROUTING --${C_R}"
    iptables -t nat -L PREROUTING -n | grep -E "DNAT|^target|^Chain" || echo "(none)"
    echo; echo "${C_DIM}-- ufw route rules --${C_R}"
    ufw status | grep -E "ALLOW FWD" || echo "(none)"
}

cmd_remove_all() {
    local f
    for f in "${FORWARDS[@]:-}"; do
        [[ -n $f ]] || continue
        ufw route delete allow $(ufw_rule_text "$f") >/dev/null 2>&1 || true
    done
    FORWARDS=(); save_state; apply
    echo "all forwards removed"
}

# ---------------------------------------------------------------- TUI -------
draw() {
    clear
    echo "${C_B}╭──────────────────────────────────────────────────────────────╮${C_R}"
    echo "${C_B}│${C_R} ${C_G}PortRelay${C_R}  ${C_DIM}v$VERSION tailnet relay port forwards${C_R}          ${C_B}│${C_R}"
    echo "${C_B}╰──────────────────────────────────────────────────────────────╯${C_R}"
    echo
    if [[ ${#FORWARDS[@]} -eq 0 ]]; then
        echo "  ${C_DIM}(no forwards yet — press A to add one)${C_R}"
    else
        printf "  ${C_DIM}%-4s %-3s %-12s %-5s %-8s %s${C_R}\n" ID EN IFACE PROTO EPORT "DESTINATION"
        local f en
        for f in "${FORWARDS[@]:-}"; do
            [[ -n $f ]] || continue
            en=$(field "$f" 1)
            local mark="●"; [[ $en == n ]] && mark="${C_DIM}○${C_R}"
            printf "  %-4s %s   %-12s %-5s %-8s ${C_G}%s${C_R}(%s):%s\n" \
                "$(field "$f" 0)" "$mark" "$(field "$f" 2)" \
                "$(field "$f" 3)" "$(field "$f" 4)" \
                "$(field "$f" 5)" "$(field "$f" 6)" "$(field "$f" 7)"
        done
    fi
    echo
    echo "  ${C_Y}A${C_R}dd  ${C_Y}D${C_R}elete  ${C_Y}T${C_R}oggle  ${C_Y}L${C_R}ive rules  ${C_Y}R${C_R}e-apply  ${C_Y}Q${C_R}uit"
    echo
}

pick_iface() {
    local ifaces=() i
    ifaces+=(any)
    while read -r i; do [[ $i == lo ]] || ifaces+=("$i"); done < <(ls /sys/class/net)
    PS3="interface: "
    select iface in "${ifaces[@]}"; do
        [[ -n $iface ]] && return 0
        return 1
    done
    return 1
}

pick_dest() {
    local machines=() names=() line ip
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        ip=$(awk '{print $1}' <<< "$line"); names+=("${line#*  }")
        machines+=("$line")
    done < <(ts_machines)
    echo "  tailnet machines:"
    local i=1
    for m in "${machines[@]}"; do echo "   $i) $m"; ((i++)); done
    echo "   $i) custom IP / hostname"
    read -r -p "destination: " pick
    if [[ $pick =~ ^[0-9]+$ ]] && (( pick == i )); then
        read -r -p "IP or tailnet hostname: " d
        DEST_IP=$(resolve_dest "$d"); DEST_NAME=$d
    elif [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick < i )); then
        DEST_NAME=$(awk '{print $1}' <<< "${machines[$((pick-1))]}")
        DEST_IP=$(awk '{print $2}' <<< "${machines[$((pick-1))]}")
    else
        return 1
    fi
}

wizard_add() {
    echo "${C_B}── add a forward ──${C_R}"
    pick_iface        || return 1
    local iface=$iface
    read -r -p "external port (arriving on this machine): " ext
    valid_port "$ext" || { pause "bad port"; return 1; }
    read -r -p "protocol — [t]cp, [u]dp, [b]oth: " p
    local proto
    case $p in t*|T*) proto=tcp;; u*|U*) proto=udp;; b*|B*) proto="tcp udp";; *) pause "bad proto"; return 1;; esac
    pick_dest         || return 1
    read -r -p "destination port on $DEST_NAME: " dport
    valid_port "$dport" || { pause "bad port"; return 1; }

    for p in $proto; do
        local id; id=$(next_id)
        FORWARDS+=("$id|y|$iface|$p|$ext|$DEST_NAME|$DEST_IP|$dport")
    done
    save_state; apply
    pause "applied! Enter to continue"
}

tui_delete() {
    cmd_list
    read -r -p "id to delete (blank=cancel): " id
    [[ -n $id ]] || return 0
    cmd_remove "$id"; pause "deleted. Enter to continue"
}

tui_toggle() {
    cmd_list
    read -r -p "id to toggle (blank=cancel): " id
    [[ -n $id ]] || return 0
    cmd_toggle "$id"; pause "toggled. Enter to continue"
}

tui() {
    [[ -t 0 ]] || die "interactive mode needs a terminal (use CLI subcommands instead)"
    while true; do
        draw
        read -rsn1 key
        case $key in
            a|A) wizard_add ;;
            d|D) tui_delete ;;
            t|T) tui_toggle ;;
            l|L) clear; cmd_status; pause "Enter to continue" ;;
            r|R) apply; pause "re-applied. Enter to continue" ;;
            q|Q) clear; exit 0 ;;
        esac
    done
}

# ---------------------------------------------------------------- main ------
need_root
load_state

case ${1:-} in
    ""|tui)   check_env; tui ;;
    init)     check_env; cmd_init ;;
    add)      shift; check_env; [[ $# -ge 5 ]] || die "usage: portrelay add <iface|any> <extport> <tcp|udp|both> <dest> <dport> [name]"; cmd_add "$@" ;;
    remove|rm) shift; cmd_remove "${1:?id}";;
    toggle)   shift; cmd_toggle "${1:?id}";;
    list|ls)  cmd_list ;;
    status)   cmd_status ;;
    apply)    check_env; apply ;;
    remove-all) cmd_remove_all ;;
    -v|--version) echo "portrelay $VERSION" ;;
    *) echo "usage: portrelay [tui|init|add|remove|toggle|list|status|apply|remove-all]"; exit 1 ;;
esac
