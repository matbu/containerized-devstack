#!/usr/bin/env bash
# containerized-devstack orchestrator (run from your workstation).
#
#   ./run.sh all       # prep host + build image + start container + stack  (default)
#   ./run.sh sync      # copy project to the host
#   ./run.sh prep      # create podman network + dirs + modules on the host
#   ./run.sh build     # build the container image on the host
#   ./run.sh up        # start (or recreate) the systemd container
#   ./run.sh stack     # run DevStack inside the container (the long step)
#   ./run.sh route     # add a host route to the floating range (reach VM FIPs)
#   ./run.sh push      # tag + push the image to the registry
#   ./run.sh info      # print access info (API/Horizon URLs, VMs)
#   ./run.sh shell     # root shell in the container
#   ./run.sh logs      # tail stack.sh.log
#   ./run.sh destroy   # remove container (keeps network + data)
#   ./run.sh nuke      # remove container, network, route and data (careful)
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./config.env

SSH=(ssh "${LAB_HOST}")
remote_env() {
    cat <<EOF
export HOST_DATA_DIR='${HOST_DATA_DIR}' PDS_NET='${PDS_NET}' PDS_SUBNET='${PDS_SUBNET}' PDS_GW='${PDS_GW}'
EOF
}

do_sync() {
    echo ">> syncing project to ${LAB_HOST}:${REMOTE_DIR}"
    "${SSH[@]}" "mkdir -p '${REMOTE_DIR}'"
    rsync -az --delete --exclude '.git' ./ "${LAB_HOST}:${REMOTE_DIR}/"
}

do_prep() {
    echo ">> preparing host"
    "${SSH[@]}" "$(remote_env); bash '${REMOTE_DIR}/scripts/host-prep.sh'"
}

do_build() {
    echo ">> building image ${IMAGE} (branch ${DEVSTACK_BRANCH})"
    "${SSH[@]}" "cd '${REMOTE_DIR}' && podman build --build-arg DEVSTACK_BRANCH='${DEVSTACK_BRANCH}' -t '${IMAGE}' -f Containerfile ."
}

do_up() {
    echo ">> (re)starting container ${CONTAINER} on ${PDS_NET} (${CONTAINER_IP})"
    "${SSH[@]}" bash -s <<EOF
set -e
podman rm -f '${CONTAINER}' 2>/dev/null || true
podman run -d --name '${CONTAINER}' \
    --privileged \
    --systemd=always \
    --hostname '${CONTAINER}' \
    --network '${PDS_NET}' --ip '${CONTAINER_IP}' \
    --device /dev/kvm \
    -v '${HOST_DATA_DIR}':/opt/stack/data \
    -v '${REMOTE_DIR}':/pds:ro \
    '${IMAGE}'
echo "waiting for systemd inside the container..."
for i in \$(seq 1 30); do
    if podman exec '${CONTAINER}' systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then
        break
    fi
    sleep 1
done
podman exec '${CONTAINER}' systemctl is-system-running || true
EOF
}

do_stack() {
    echo ">> running DevStack inside ${CONTAINER} (long; ~20-40 min)"
    "${SSH[@]}" "podman exec \
        -e ADMIN_PASSWORD='${ADMIN_PASSWORD}' \
        -e CONTAINER_IP='${CONTAINER_IP}' \
        -e FIXED_RANGE='${FIXED_RANGE}' \
        -e FLOATING_RANGE='${FLOATING_RANGE}' \
        -e FLOATING_GW='${FLOATING_GW}' \
        -e FLOATING_POOL_START='${FLOATING_POOL_START}' \
        -e FLOATING_POOL_END='${FLOATING_POOL_END}' \
        -e HORIZON_PORT='${HORIZON_PORT}' \
        '${CONTAINER}' bash -c 'if [ -f /pds/scripts/container-stack.sh ]; then exec bash /pds/scripts/container-stack.sh; else exec /usr/local/bin/container-stack.sh; fi'"
}

# Reach VM floating IPs from the host: route the floating range to the container.
do_route() {
    echo ">> adding host route ${FLOATING_RANGE} via ${CONTAINER_IP}"
    "${SSH[@]}" "ip route replace '${FLOATING_RANGE}' via '${CONTAINER_IP}'"
}

do_info() {
    cat <<EOF
Access (services bind to the container IP ${CONTAINER_IP} on podman net ${PDS_NET}):

  From the host (${LAB_HOST#*@}):
    Horizon:   http://${CONTAINER_IP}/dashboard      (admin / ${ADMIN_PASSWORD})
    Keystone:  http://${CONTAINER_IP}/identity

  From your workstation, tunnel through the host:
    ssh -L 8080:${CONTAINER_IP}:80 -L 5000:${CONTAINER_IP}:5000 ${LAB_HOST}
    then open http://localhost:8080/dashboard

  Credentials file inside the container: /opt/stack/devstack/openrc
  VMs (on the host's KVM) are listed with:
    ssh ${LAB_HOST} "podman exec ${CONTAINER} virsh -c qemu:///system list --all"
EOF
}

do_push() {
    echo ">> pushing ${IMAGE} to ${REGISTRY_IMAGE}:{${REGISTRY_TAG},latest} (needs: podman login quay.io on the host)"
    "${SSH[@]}" bash -s <<EOF
set -e
podman tag '${IMAGE}' '${REGISTRY_IMAGE}:${REGISTRY_TAG}'
podman tag '${IMAGE}' '${REGISTRY_IMAGE}:latest'
podman push '${REGISTRY_IMAGE}:${REGISTRY_TAG}'
podman push '${REGISTRY_IMAGE}:latest'
echo "pushed ${REGISTRY_IMAGE}:${REGISTRY_TAG} and :latest"
EOF
}

do_shell()  { "${SSH[@]}" -t "podman exec -it '${CONTAINER}' bash"; }
do_logs()   { "${SSH[@]}" "tail -n 80 -f '${HOST_DATA_DIR}/logs/stack.sh.log'"; }
do_destroy(){ "${SSH[@]}" "podman rm -f '${CONTAINER}' 2>/dev/null || true"; echo "container removed (network + data kept)"; }
do_nuke() {
    "${SSH[@]}" bash -s <<EOF
podman rm -f '${CONTAINER}' 2>/dev/null || true
podman network rm '${PDS_NET}' 2>/dev/null || true
ip route del '${FLOATING_RANGE}' via '${CONTAINER_IP}' 2>/dev/null || true
rm -rf '${HOST_DATA_DIR}'
echo "nuked container, network, route and ${HOST_DATA_DIR}"
EOF
}

case "${1:-all}" in
    sync)    do_sync ;;
    prep)    do_sync; do_prep ;;
    build)   do_sync; do_build ;;
    up)      do_up ;;
    stack)   do_stack ;;
    route)   do_route ;;
    push)    do_push ;;
    info)    do_info ;;
    shell)   do_shell ;;
    logs)    do_logs ;;
    destroy) do_destroy ;;
    nuke)    do_nuke ;;
    all)     do_sync; do_prep; do_build; do_up; do_stack; do_route; do_info ;;
    *) echo "unknown command: $1"; grep -E '^#   \./run.sh' "$0" | sed 's/^#   //'; exit 1 ;;
esac
