#!/bin/bash
# Multi-VM vhost-user test: two VMs attached to the same VLAN through
# vhost-user ports, verifying the dataplane end to end:
#   1. both guests obtain DHCP leases (broadcast + unicast over vhost-user)
#   2. east-west: the guests ping each other through the switch
#      (vhost-user -> vhost-user forwarding path)
#   3. north-south: the guests reach the outside world through the gateway
#      (ICMP via the ping forwarder, DNS via the gateway proxy, HTTP via NAT)
source "$(dirname "$0")/lib.sh"

IMAGE="$ARTIFACTS/debian.qcow2"
SEED="$ARTIFACTS/seed.img"
[ -f "$IMAGE" ] || skip "no $IMAGE; run ./init_artifacts.sh first"
[ -f "$SEED" ] || skip "no $SEED; run ./init_artifacts.sh first"
command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"

VLAN=160
GW=10.0.160.2
MAC1=52:54:00:de:ad:01
MAC2=52:54:00:de:ad:02

build_gvswitch
start_gvswitch
# Internet routing and the DNS proxy must be enabled explicitly for the
# north-south checks (DHCP hands the gateway out as the resolver).
api POST /api/v1/gateways \
    "{\"vlan\":$VLAN,\"ipv4\":{\"address\":\"$GW\",\"prefix_len\":24},\"enable_internet_routing\":true,\"dns_proxy\":true}" >/dev/null
ok "gateway vlan=$VLAN $GW/24 (internet routing + dns proxy on)"
enable_dhcp4 $VLAN 10.0.160.100 10.0.160.199

ACCEL=""
[ -w /dev/kvm ] && ACCEL="-enable-kvm -cpu host"

# start_vm N MAC MODE -> boots VM N on a fresh vhost-user switchport.
# MODE=server: the switch listens, QEMU dials (created before QEMU starts).
# MODE=client: QEMU is the unix server (server=on, blocks until the backend
# connects); the switch dials in once the socket appears.
start_vm() {
    local n="$1" mac="$2" mode="$3"
    local vusock="$WORK/vu$n.sock" qga="$WORK/qga$n.sock"
    local chardev="socket,id=c0,path=$vusock"
    if [ "$mode" = server ]; then
        api POST /api/v1/ports \
            "{\"identifier\":\"vm$n\",\"vlan\":$VLAN,\"mode\":\"server\",\"transport\":\"vhost-user\",\"local\":\"$vusock\"}" >/dev/null
    else
        chardev="$chardev,server=on"
    fi
    qemu-system-x86_64 \
        -m 1024 -smp 2 $ACCEL \
        -chardev "$chardev" \
        -object memory-backend-memfd,id=mem0,share=on,size=1024M \
        -machine memory-backend=mem0 \
        -snapshot -display none -serial null -monitor none \
        -drive file="$IMAGE",if=virtio,format=qcow2 \
        -drive file="$SEED",if=virtio,format=raw \
        -netdev vhost-user,id=n0,chardev=c0 \
        -device virtio-net-pci,netdev=n0,mac="$mac" \
        -chardev socket,path="$qga",server=on,wait=off,id=qga0 \
        -device virtio-serial \
        -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
        &
    add_cleanup "kill $! 2>/dev/null"
    if [ "$mode" = client ]; then
        wait_for 15 "[ -S '$vusock' ]" || fail "QEMU never created $vusock"
        api POST /api/v1/ports \
            "{\"identifier\":\"vm$n\",\"vlan\":$VLAN,\"mode\":\"client\",\"transport\":\"vhost-user\",\"remote\":\"$vusock\"}" >/dev/null
    fi
    ok "VM$n booting (vhost-user $mode mode, mac $mac)"
}

# qga_exec QGA_SOCK PATH [ARG...] -> command stdout; nonzero on guest failure
qga_exec() {
    local sock="$1" path="$2"
    shift 2
    local args="" a
    for a in "$@"; do args="$args${args:+,}\"$a\""; done
    local r pid
    r=$(qga_call "$sock" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"$path\",\"arg\":[$args],\"capture-output\":true}}")
    pid=$(echo "$r" | jq -r '.return.pid // empty')
    [ -n "$pid" ] || return 1
    local i st
    for i in $(seq 1 60); do
        st=$(qga_call "$sock" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")
        if echo "$st" | jq -e '.return.exited == true' >/dev/null 2>&1; then
            echo "$st" | jq -r '.return."out-data" // empty' | base64 -d 2>/dev/null
            [ "$(echo "$st" | jq -r '.return.exitcode')" = 0 ]
            return
        fi
        sleep 1
    done
    return 1
}

log "booting two debian VMs (vm1: server mode, vm2: client mode)"
start_vm 1 $MAC1 server
start_vm 2 $MAC2 client

BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
log "waiting for both DHCP leases (up to ${BOOT_TIMEOUT}s)"
wait_for "$BOOT_TIMEOUT" \
    "api GET /api/v1/gateways/$VLAN/dhcp4/leases | jq -e 'length == 2' >/dev/null" \
    || fail "expected 2 DHCP leases, got: $(api GET /api/v1/gateways/$VLAN/dhcp4/leases)"

LEASES=$(api GET "/api/v1/gateways/$VLAN/dhcp4/leases")
IP1=$(echo "$LEASES" | jq -r '.[] | select(.port_identifier == "vm1") | .ip')
IP2=$(echo "$LEASES" | jq -r '.[] | select(.port_identifier == "vm2") | .ip')
[ -n "$IP1" ] && [ -n "$IP2" ] || fail "leases not tied to both switchports: $LEASES"
ok "leases: vm1=$IP1 vm2=$IP2"

log "waiting for guest agents"
wait_for 120 "qga_call '$WORK/qga1.sock' '{\"execute\":\"guest-ping\"}' | grep -q return" \
    || fail "VM1 guest agent never came up"
wait_for 120 "qga_call '$WORK/qga2.sock' '{\"execute\":\"guest-ping\"}' | grep -q return" \
    || fail "VM2 guest agent never came up"
ok "guest agents up"

# --- east-west: VM <-> VM through the switch ---
qga_exec "$WORK/qga1.sock" /usr/bin/ping -c3 -W2 "$IP2" >/dev/null \
    || fail "VM1 cannot ping VM2 ($IP2)"
ok "east-west: VM1 -> VM2 ping"
qga_exec "$WORK/qga2.sock" /usr/bin/ping -c3 -W2 "$IP1" >/dev/null \
    || fail "VM2 cannot ping VM1 ($IP1)"
ok "east-west: VM2 -> VM1 ping"

# --- north-south: gateway, then the outside world ---
qga_exec "$WORK/qga1.sock" /usr/bin/ping -c2 -W2 "$GW" >/dev/null \
    || fail "VM1 cannot ping its gateway $GW"
ok "north-south: VM1 -> gateway ping"

# 8.8.8.8 rides the default route; IPs with specific host routes (e.g. a
# DHCP-injected 1.1.1.1/32 on this host) classify as host routing instead.
qga_exec "$WORK/qga1.sock" /usr/bin/ping -c3 -W4 8.8.8.8 >/dev/null \
    || fail "VM1 cannot ping 8.8.8.8 (external ICMP)"
ok "north-south: VM1 -> 8.8.8.8 ping (external ICMP via ping forwarder)"

HTTP1=$(qga_exec "$WORK/qga1.sock" /usr/bin/curl -sf --max-time 20 \
    -o /dev/null -w '%{http_code}' http://deb.debian.org/) \
    || fail "VM1 HTTP to deb.debian.org failed (DNS or NAT broken)"
echo "$HTTP1" | grep -q 200 || fail "VM1 HTTP status: $HTTP1"
ok "north-south: VM1 -> http://deb.debian.org (DNS + NAT, HTTP $HTTP1)"

HTTP2=$(qga_exec "$WORK/qga2.sock" /usr/bin/curl -sf --max-time 20 \
    -o /dev/null -w '%{http_code}' http://deb.debian.org/) \
    || fail "VM2 HTTP to deb.debian.org failed (DNS or NAT broken)"
echo "$HTTP2" | grep -q 200 || fail "VM2 HTTP status: $HTTP2"
ok "north-south: VM2 -> http://deb.debian.org (DNS + NAT, HTTP $HTTP2)"

ok "test_vhost_multi passed"
