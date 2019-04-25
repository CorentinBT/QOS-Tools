#!/bin/bash

TC=/sbin/tc
DEV=$(ip route show | head -1 | awk '{print $5}')

$TC qdisc del dev $DEV root 2> /dev/null > /dev/null
$TC qdisc del dev $DEV ingress 2> /dev/null > /dev/null
$TC qdisc del dev ifb0 root 2> /dev/null > /dev/null

ip link set ifb0 down 2> /dev/null > /dev/null
rmmod ifb 2> /dev/null > /dev/null
