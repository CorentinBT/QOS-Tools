#!/bin/bash

TC=/sbin/tc
DEV=$(ip route show | head -1 | awk '{print $5}')
BASEDIR=$(dirname $(readlink -f $0))
CGCLASSID=0x10010
MARKID=42
CGNAME=group$$
config_file_name=tmp_iptables_rule
cgroup_config=tmp_cg_config*
UNAME=root

init_cgroup_net() { # $1 : CGNAME, $2 : CGCLASSID
  cgcreate -g net_cls:/$1
  cgset -r net_cls.classid=$2 /$1
}

init_cgroup_mem() {
  cgcreate -g memory:/$1
  cgset -r memory.limit_in_bytes=$2 /$1
}

delete_cgroup_net() { # $1 : CGNAME
  cgdelete -g net_cls:/$1 2> /dev/null
}

delete_cgroup_mem() { # $1 : CGNAME
  cgdelete -g memory:/$1 2> /dev/null
}

limit_rate_ingress() { # $1 : D_LIMIT, $2 : CGCLASSID, $3 : MARKID

  iptables -N QOS
  ip6tables -N QOS

  iptables -I OUTPUT 1 -m cgroup --cgroup $2 -j MARK --set-mark $3
  if [ $? -ne 0 ]; then
    return 1
  fi
  iptables -A POSTROUTING -t mangle -j CONNMARK --save-mark
  if [ $? -ne 0 ]; then
    return 1
  fi
  iptables -A PREROUTING -t mangle -j CONNMARK --restore-mark
  if [ $? -ne 0 ]; then
    return 1
  fi
  iptables -I INPUT 1 -m connmark --mark $3 -j QOS
  if [ $? -ne 0 ]; then
    return 1
  fi
  iptables -A QOS -p tcp -m hashlimit --hashlimit-name hl1 --hashlimit-above $1/s -j DROP
  if [ $? -ne 0 ]; then
    return 1
  fi

  ip6tables -I OUTPUT 1 -m cgroup --cgroup $2 -j MARK --set-mark $3
  if [ $? -ne 0 ]; then
    return 1
  fi
  ip6tables -A POSTROUTING -t mangle -j CONNMARK --save-mark
  if [ $? -ne 0 ]; then
    return 1
  fi
  ip6tables -A PREROUTING -t mangle -j CONNMARK --restore-mark
  if [ $? -ne 0 ]; then
    return 1
  fi
  ip6tables -I INPUT 1 -m connmark --mark $3 -j QOS
  if [ $? -ne 0 ]; then
    return 1
  fi
  ip6tables -A QOS -p tcp -m hashlimit --hashlimit-name hl1 --hashlimit-above $1/s -j DROP
  if [ $? -ne 0 ]; then
    return 1
  fi
  return 0
}

limit_rate_latency_egress() { # $1 : interface, $2 : rate, $3 : latency, $4 : MARKID
  $TC qdisc del dev $1 root 2> /dev/null > /dev/null
  $TC qdisc add dev $1 root handle 1: htb
  $TC class add dev $1 parent 1: classid 1:10 htb rate $2 ceil $2
  $TC qdisc add dev $1 parent 1:10 handle 2: netem delay $3
  $TC filter add dev $1 parent 1: handle $4 fw classid 1:10
  # $TC filter add dev $1 parent 1: protocol ip prio 1 handle 1: cgroup
}

limit_latency_egress_ip() { # $1 : latency, $2 : ip
  $TC qdisc del dev $DEV root 2> /dev/null > /dev/null
  $TC qdisc add dev $DEV root handle 1: htb
  $TC class add dev $DEV parent 1: classid 1:10 htb rate -1mbit ceil -1mbit
  $TC qdisc add dev $DEV parent 1:10 handle 2: htb
  $TC class add dev $DEV parent 2: classid 2:10 htb rate -1mbit ceil -1mbit 
  $TC class add dev $DEV parent 2: classid 2:11 htb rate -1mbit ceil -1mbit 
  $TC qdisc add dev $DEV parent 2:10 handle 3: netem delay "$1"

  $TC filter add dev $DEV parent 1: protocol ip prio 1 handle 1: cgroup
  $TC filter add dev $DEV parent 2: prio 1 protocol ip u32 \
        match ip dst "$2" classid 2:10
}


delete_limit_rate_latency_egress() {
  $TC qdisc del dev $DEV root 2> /dev/null > /dev/null
}

delete_limit_rate_ingress() { # $1 : CGCLASSID, $2 : MARKID, $3 : D_LIMIT
  iptables -D OUTPUT -m cgroup --cgroup $1 -j MARK --set-mark $2 2> /dev/null
  iptables -D POSTROUTING -t mangle -j CONNMARK --save-mark 2> /dev/null
  iptables -D PREROUTING -t mangle -j CONNMARK --restore-mark 2> /dev/null
  iptables -D INPUT -m connmark --mark $2 -j QOS 2> /dev/null
  iptables -D QOS -p tcp -m hashlimit --hashlimit-name hl1 --hashlimit-above $3/s -j DROP 2> /dev/null

  ip6tables -D OUTPUT -m cgroup --cgroup $1 -j MARK --set-mark $2 2> /dev/null
  ip6tables -D POSTROUTING -t mangle -j CONNMARK --save-mark 2> /dev/null
  ip6tables -D PREROUTING -t mangle -j CONNMARK --restore-mark 2> /dev/null
  ip6tables -D INPUT -m connmark --mark $2 -j QOS 2> /dev/null
  ip6tables -D QOS -p tcp -m hashlimit --hashlimit-name hl1 --hashlimit-above $3/s -j DROP 2> /dev/null

  iptables -X QOS
  ip6tables -X QOS

  rm /tmp/$config_file_name 2> /dev/null
}

delete_all() {
  delete_limit_rate_latency_egress
  delete_limit_rate_ingress $CGCLASSID $MARKID $D_LIMIT
  delete_cgroup_net $CGNAME
  delete_cgroup_mem $CGNAME
}

# Help
display_help() {
echo -e "Usage : $0 [\e[4mLIMITS\e[24m] [\e[4mOPTIONS\e[24m] -- \e[4mPROG\e[24m
Run a \e[4mPROG\e[24m under network and memory limitations.
Libcgroups-tools library is needed.
\e[1m\e[4mLIMITS\e[0m:\n
\e[1m-m, --memory\e[0m       Sets the maximum amount of user memory (including file cache).
                   If no units are specified, the value is interpreted as bytes.
                   However, it is possible to use suffixes to represent larger
                   units — k or K for kilobytes, m or M for megabytes, and g or
                   G for gigabytes.
\e[1m-u, --upload\e[0m       Limits upload speed. (see below for units)
\e[1m-d, --download\e[0m     Limits download speed. (see below for units)
\e[1m-l, --latency\e[0m      Adds latency. Egress latency only. (see below for units)
\e[1m\e[4mOPTIONS\e[0m:\n
\e[1m-b, --username\e[0m     Specifies a username, the process will run with
                   these privileges, default : root
\e[1m--interface\e[0m        Specifies an interface name, default : $DEV
\e[1m--markid\e[0m           Specifies a MarkID which will be applied to the
                   packets, default : $MARKID
\e[1m-x, --delete\e[0m       Removes all limits
\e[1m-h, --help\e[0m         Shows this help
UNITS:\n
        bit or a bare number Bits per second
        kbit   Kilobits per second
        mbit   Megabits per second
        gbit   Gigabits per second
        tbit   Terabits per second
        bps    Bytes per second
        kbps   Kilobytes per second
        mbps   Megabytes per second
        gbps   Gigabytes per second
        tbps   Terabytes per second
        s, sec or secs Whole seconds
        ms, msec or msecs Milliseconds
        us, usec, usecs or a bare number Microseconds.
For the download rate, because of iptables's hashlimit limitations
only bytes units are valid and the maximum value is 400mbps."
}

# Helper functions to handle unit conversion
toBytes() {
  echo $1 | awk \
          'BEGIN{IGNORECASE = 1}
          /[0-9]$/{print $1};
          /kbps?$/{printf "%ukb\n", $1; exit 0};
          /mbps?$/{printf "%umb\n", $1; exit 0};
          /gbps?$/{printf "%ugb\n", $1; exit 0};
          /bps?$/{printf "%ub\n", $1};'
}

# Default highest values
U_LIMIT=400gbps
D_LIMIT=400mb
DELAY_LIMIT=0

TEMP=`getopt -o hm:d:u:l:x --long help,delete,ip:,username:,memory:,latency:,download:,upload:,interface:,markid: \
      -n 'cg_limit' -- "$@"`

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

eval set -- "$TEMP"

while true; do
  case "$1" in
  -m | --memory )
    M_FLAG=1; M_LIMIT="$2"; shift 2 ;;

	-u | --upload )
		U_FLAG=1; U_LIMIT="$2"; shift 2 ;;

	-d | --download )
		D_FLAG=1
    if [[ $2 =~ .*bit ]]; then
      echo "Please provide the download rate in bytes" >&2
      exit 1
    fi
    D_LIMIT=$(toBytes "$2")
    shift 2
		;;

  -b | --username)
    UNAME="$2"; shift 2 ;;

  -l | --latency)
    DELAY_FLAG=1; DELAY_LIMIT="$2"; shift 2 ;;

  --interface)
    DEV="$2"; shift 2 ;;

  --markid)
    MARKID="$2"; shift 2 ;;

  --ip)
    IP_FLAG=1; IP="$2"; shift 2 ;;

  -h | --help)
    display_help; exit 2 ;;

  -x | --delete)
    if [[ $EUID -eq 0 ]]; then
      delete_limit_rate_latency_egress
      delete_limit_rate_ingress $CGCLASSID $MARKID
      delete_cgroup_net $CGNAME
      exit 0
    fi
    exit 1
    ;;

  --)
    shift; break ;;

  *)
    exit 1
    ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

if [[ -z "$UNAME" ]]; then
  echo "You have to provide a username (-b option)"
  exit 1
fi

if [[ "$M_FLAG" -eq "1" ]]; then
  init_cgroup_mem $CGNAME $M_LIMIT
  if [ $? -ne 0 ]; then
    delete_cgroup_mem $CGNAME
    exit 1
  fi
  cgclassify -g memory:/$CGNAME $$
fi

if [[ "$IP_FLAG" -eq "1" ]] && [[ "$DELAY_FLAG" -eq "1" ]]; then
  init_cgroup_net $CGNAME $CGCLASSID
  limit_latency_egress_ip $DELAY_LIMIT $IP
  if [ $? -ne 0 ]; then
    delete_limit_rate_latency_egress
    delete_cgroup_net $CGNAME
    exit 1
  fi
  cgclassify -g net_cls:/$CGNAME $$

elif [[ "$U_FLAG" -eq "1" ]] || [[ "$DELAY_FLAG" -eq "1" ]] || [[ "$D_FLAG" -eq "1" ]]; then

  init_cgroup_net $CGNAME $CGCLASSID
  limit_rate_latency_egress $DEV $U_LIMIT $DELAY_LIMIT $MARKID
  limit_rate_ingress $D_LIMIT $CGCLASSID $MARKID
  if [ $? -ne 0 ]; then
    delete_limit_rate_latency_egress
    delete_limit_rate_ingress $CGCLASSID $MARKID
    delete_cgroup_net $CGNAME
    exit 1
  fi
  cgclassify -g net_cls:/$CGNAME $$
fi

# now executing the program
sudo -u $UNAME -E env "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" $@

delete_all

exit 0
