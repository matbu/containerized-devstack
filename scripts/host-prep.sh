#!/usr/bin/env bash
# Runs ON THE HOST (the hypervisor). Minimal, non-invasive prep so the
# containerized DevStack can run isolated alongside other workloads on the
# host. Idempotent.
set -euo pipefail

: "${HOST_DATA_DIR:?}" "${PDS_NET:?}" "${PDS_SUBNET:?}" "${PDS_GW:?}"

echo "[host-prep] host data dir ${HOST_DATA_DIR} (bind-mounted to /opt/stack/data)"
mkdir -p "${HOST_DATA_DIR}"
chmod 0777 "${HOST_DATA_DIR}" || true

echo "[host-prep] kernel modules for the container's OVN/OVS + tunnels"
# These modules are global; the container (own netns) uses them via /dev/kvm +
# privileged. They are almost certainly already loaded (the host runs OVS), but
# ensure them so the container's ovs-vswitchd/ovn work.
for m in kvm openvswitch geneve vhost_net nf_conntrack; do
    modprobe "$m" 2>/dev/null || true
done

echo "[host-prep] dedicated podman network ${PDS_NET} (${PDS_SUBNET})"
if ! podman network exists "${PDS_NET}" 2>/dev/null; then
    podman network create \
        --subnet "${PDS_SUBNET}" --gateway "${PDS_GW}" \
        "${PDS_NET}"
fi

echo "[host-prep] done."
