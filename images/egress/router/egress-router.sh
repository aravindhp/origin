#!/bin/bash

# OpenShift egress router setup script

set -o errexit
set -o nounset
set -o pipefail

IP_REGEX="[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+"

if [[ ! "${EGRESS_SOURCE:-}" =~ ^${IP_REGEX}$ ]]; then
    echo "EGRESS_SOURCE unspecified or invalid"
    exit 1
fi
if [[ ! "${EGRESS_DESTINATION:-}" =~ ^${IP_REGEX}$ ]]; then
    echo "EGRESS_DESTINATION unspecified or invalid"
    exit 1
fi
if [[ ! "${EGRESS_GATEWAY:-}" =~ ^${IP_REGEX}$ ]]; then
    echo "EGRESS_GATEWAY unspecified or invalid"
    exit 1
fi

if [[ -n "${EGRESS_ROUTER_DEBUG:-}" ]]; then
    set -x
fi

# The pod may die and get restarted; only try to add the
# address/route/rules if they are not already there.
if ! ip route get "${EGRESS_GATEWAY}" | grep -q macvlan0; then
    ip addr add "${EGRESS_SOURCE}"/32 dev macvlan0
    ip link set up dev macvlan0

    ip route add "${EGRESS_GATEWAY}"/32 dev macvlan0
    ip route del default
    ip route add default via "${EGRESS_GATEWAY}" dev macvlan0

    iptables -t nat -A PREROUTING -i eth0 -j DNAT --to-destination "${EGRESS_DESTINATION}"
    iptables -t nat -A POSTROUTING -j SNAT --to-source "${EGRESS_SOURCE}"
fi

# Update neighbor ARP caches in case another node previously had the IP. (This is
# the same code ifup uses.)
arping -q -A -c 1 -I macvlan0 "${EGRESS_SOURCE}"
( sleep 2;
  arping -q -U -c 1 -I macvlan0 "${EGRESS_SOURCE}" || true ) > /dev/null 2>&1 < /dev/null &

# Now we just wait until we are killed...
#
# Kubernetes will use SIGTERM to kill us, but bash ignores SIGTERM by
# default in interactive shells, and it thinks this shell is
# interactive due to the way in which docker invokes it. We can get
# bash to react to SIGTERM if we explicitly set a trap for it, except
# that bash doesn't process signal traps while it is waiting for a
# process to finish, and we have to be waiting for a process to finish
# because there's no way to sleep forever within bash.
#
# Fortunately, signal traps do interrupt the "wait" builtin. So...
# set up a SIGTERM trap, run a command that sleeps forever *in the
# background*, and then wait for either the command to finish or the
# signal to arrive.

trap "exit" TERM
tail -f /dev/null &
wait

# We don't have to do any cleanup because deleting the network
# namespace will clean everything up for us.
