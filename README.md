### cg_limit

Script to apply network and/or memory restrictions to a process and children of this process. This is useful to watch the behavior of a workload under some limitations.

It uses the traffic control, cgroup and iptables utilities of Linux. The libcgroup-tools library is needed as well to correctly manage cgroups . 

To restrict the physical amount of memory, the script simply creates a new cgroup folder (usually in `/sys/fs/cgroup/memory`) and changes the value in`memory.limit_in_bytes` file to the desired limit value. The process is then associated to this cgroup by appending his pid to the `tasks` file. 

To track the network usage of a particular process, the script creates an iptables rule to mark all packets sent and received by the process. 

For the latency and upload limit, the script creates two new queue discipline. The `htb` discipline which allows to redirect marked packets, using a filter, to the  `netem` discipline which adds delay to outgoing packets. An intermediate `htb` class, between these two queue disciplines, is also created to limit the incoming packet to a desired rate (the upload rate). For example with a delay of `50ms` and upload limit of `1mbit` , the queue tree can be visualized as : 
<p align="center"> 
<img src="https://user-images.githubusercontent.com/32176761/44657386-f3af3a00-a9fc-11e8-83f0-a0bea57e3bb9.png">
</p>

The traffic control utility cannot be used to control ingress traffic. Thus for the download limit, the script uses an iptables module called `hashlimit` which drops incoming packets that exceed a desired limit (the download rate).  

This script cannot be used to increase ingress latency. 

### lim_latency

Script created in case we want to control both ingress and egress latency. These restrictions are not only applied to a process and children of this process but to all communications to a subnetwork (specified by a netmask).

### del_lim_latency

Script to delete all limitations created by `lim_latency` script. 