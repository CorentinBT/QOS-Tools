#!/bin/bash

ip_subnet=$1
lim=$2
if [ -z "$ip_subnet" -o -z "$lim" ]; then
  echo "Usage: $0 <subnet|ip> <latency>"
  echo "For example : './lim.sh 172.217.19.46 5ms' will add an egress latency of 5ms and ingress latency of 5ms, thus an overall of 10ms added latency to communications with 172.217.19.46"
  exit 1
fi
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

TC=/sbin/tc
DEV=$(ip route show | head -1 | awk '{print $5}')

modprobe ifb
ip link set ifb0 up

# Egress

$TC qdisc del dev $DEV root 2> /dev/null > /dev/null

$TC qdisc add dev $DEV root handle 1: htb
$TC class add dev $DEV parent 1: classid 1:10 htb rate -1mbit ceil -1mbit
$TC qdisc add dev $DEV parent 1:10 handle 2: netem delay $lim
$TC qdisc add dev $DEV parent 2: handle 3: sfq

$TC filter add dev $DEV parent 1: prio 1 protocol ip u32 \
    match ip dst $ip_subnet classid 1:10

# Ingress

$TC qdisc del dev $DEV ingress 2> /dev/null > /dev/null
$TC qdisc del dev ifb0 root 2> /dev/null > /dev/null

$TC qdisc add dev $DEV ingress

$TC filter add dev $DEV parent ffff: protocol ip u32 match ip src $ip_subnet flowid 1:1 action mirred egress redirect dev ifb0

$TC qdisc add dev ifb0 root handle 1: netem delay $lim
$TC qdisc add dev ifb0 parent 1: handle 2: sfq


