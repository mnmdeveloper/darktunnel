#!/bin/sh
set -eu
mkdir -p /data
if [ ! -s /data/server.key ]; then
  umask 077
  wg genkey > /data/server.key
fi
ip link show wg0 >/dev/null 2>&1 || ip link add wg0 type wireguard
ip address show dev wg0 | grep -q '10.79.0.1/24' || ip address add 10.79.0.1/24 dev wg0
wg set wg0 private-key /data/server.key listen-port 51820
ip link set wg0 up
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -C FORWARD -i wg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i wg0 -j ACCEPT
iptables -C FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s 10.79.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.79.0.0/24 -o eth0 -j MASQUERADE
exec /usr/local/bin/vk-turn-proxy -listen 0.0.0.0:56100 -connect 127.0.0.1:51820 -srtp -logfile /dev/stdout
