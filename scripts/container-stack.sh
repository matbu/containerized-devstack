#!/usr/bin/env bash
# Runs INSIDE the container (as root, via `podman exec`). Renders local.conf and
# runs stack.sh as the 'stack' user. The container runs its own libvirtd + OVN;
# VMs execute on the host's KVM via the passed-through /dev/kvm.
# Idempotent-ish: safe to re-run; stack.sh itself converges.
set -euo pipefail

DATA=/opt/stack/data          # DevStack data dir (bind-mounted from host /home)
VBIN="${DATA}/venv/bin"       # DevStack global venv bin

echo "[container-stack] preparing environment..."

# Sanity: KVM must be available for hardware acceleration.
if [ -e /dev/kvm ]; then
    echo "[container-stack] /dev/kvm present -> hardware KVM acceleration available"
else
    echo "[container-stack] WARNING: /dev/kvm missing - VMs would fall back to slow TCG!"
fi

# ---------------------------------------------------------------------------
# 1. Render local.conf from the template.
# ---------------------------------------------------------------------------
: "${ADMIN_PASSWORD:?}" "${CONTAINER_IP:?}"
: "${FIXED_RANGE:?}" "${FLOATING_RANGE:?}" "${FLOATING_GW:?}"
: "${FLOATING_POOL_START:?}" "${FLOATING_POOL_END:?}"

export ADMIN_PASSWORD CONTAINER_IP FIXED_RANGE FLOATING_RANGE \
       FLOATING_GW FLOATING_POOL_START FLOATING_POOL_END
# Prefer the live-synced template (bind-mounted at /pds) for fast iteration.
TMPL=/pds/local.conf.tmpl; [ -f "$TMPL" ] || TMPL=/opt/stack/local.conf.tmpl
# Only substitute our known vars (leave $NOVA_CONF etc. for DevStack).
envsubst '${ADMIN_PASSWORD} ${CONTAINER_IP} ${FIXED_RANGE} ${FLOATING_RANGE} ${FLOATING_GW} ${FLOATING_POOL_START} ${FLOATING_POOL_END}' \
    < "$TMPL" > /opt/stack/devstack/local.conf
chown stack:stack /opt/stack/devstack/local.conf
echo "[container-stack] rendered local.conf"

# ---------------------------------------------------------------------------
# 2. Data dir (bind-mounted from host) + DEST perms.
# ---------------------------------------------------------------------------
mkdir -p "${DATA}/logs" "${DATA}/nova/instances"
chown -R stack:stack "${DATA}"
# DevStack's DEST (/opt/stack) must be traversable (useradd -m makes it 0700).
chmod 0755 /opt/stack

# cinder-volume's LIO backend execs 'cinder-rtstool' by name via rootwrap, whose
# PATH doesn't include the venv bin. Expose it on /usr/local/bin (default PATH).
# The symlink may dangle until cinder is pip-installed mid-stack, then resolves.
ln -sf "${VBIN}/cinder-rtstool" /usr/local/bin/cinder-rtstool

# ---------------------------------------------------------------------------
# 3. Cinder LVM: there is no udev in the container, so LVM can't create the
#    device node to wipe a new (thin-pool) LV -> volume create fails with
#    "device not cleared". Tell LVM to manage nodes itself (no udev).
# ---------------------------------------------------------------------------
mkdir -p /etc/lvm
cat > /etc/lvm/lvmlocal.conf <<'LVM'
# containerized-devstack: no udev in the container -> let LVM manage device nodes itself
devices {
    obtain_device_list_from_udev = 0
}
activation {
    udev_sync = 0
    udev_rules = 0
}
LVM

# ---------------------------------------------------------------------------
# 3b. Cinder NFS backend: run an in-container NFS server exporting a dir on the
#     host-backed /opt/stack/data. cinder/nova mount it over loopback (vers=3).
#     This replaces iSCSI, which can't work from the container's isolated netns.
# ---------------------------------------------------------------------------
setup_nfs_server() {
    mkdir -p /opt/stack/data/cinder-nfs
    chmod 0777 /opt/stack/data/cinder-nfs
    echo "/opt/stack/data/cinder-nfs 127.0.0.1(rw,sync,no_root_squash,no_subtree_check)" > /etc/exports
    systemctl enable --now rpcbind 2>/dev/null || true
    systemctl enable rpc-statd 2>/dev/null || true
    systemctl restart nfs-server 2>/dev/null || true
    exportfs -ra 2>/dev/null || true
    echo "[container-stack] in-container NFS server: $(systemctl is-active nfs-server 2>/dev/null)"
}
setup_nfs_server

# ---------------------------------------------------------------------------
# 4. Patch DevStack's create_neutron_initial_network to restart neutron-api and
#    wait for OVN readiness before creating networks (fixes cold-start OVN race).
# ---------------------------------------------------------------------------
L3=/opt/stack/devstack/lib/neutron_plugins/services/l3
SNIP=/pds/scripts/ovn-wait.inc; [ -f "$SNIP" ] || SNIP=/opt/stack/ovn-wait.inc
if [ -f "$L3" ] && [ -f "$SNIP" ] && ! grep -q "pds-ovn-wait" "$L3"; then
    awk -v snip="$SNIP" '
        { print }
        /^function create_neutron_initial_network \{/ {
            while ((getline line < snip) > 0) print line
        }
    ' "$L3" > "${L3}.pds" && mv "${L3}.pds" "$L3"
    echo "[container-stack] patched create_neutron_initial_network with OVN-readiness wait"
fi

# ---------------------------------------------------------------------------
# 5. Run stack.sh as the stack user (this is the long part).
#
# On loaded hosts some services occasionally lose a start/bind race during
# stack.sh even with SERVICE_TIMEOUT raised. On failure we heal the
# commonly-flaky API services and re-run stack.sh once (DevStack re-runs are
# idempotent). Finally we (re)discover compute hosts so nova is usable.
# ---------------------------------------------------------------------------
run_stack() { su - stack -c 'cd /opt/stack/devstack && ./stack.sh'; }
mysql_count() { mysql -uroot -p"${ADMIN_PASSWORD}" -N -e "$1" 2>/dev/null || echo 0; }

heal_services() {
    echo "[container-stack] healing flaky API services (busy-host restart)..."
    systemctl restart \
        devstack@neutron-api devstack@g-api devstack@placement-api \
        devstack@n-api devstack@n-api-meta devstack@n-super-cond \
        devstack@n-cond-cell1 devstack@n-sch devstack@n-cpu \
        devstack@c-api devstack@c-vol 2>/dev/null || true
    # Wait for OVN to be ready (geneve pool synced + live hash-ring node).
    for i in $(seq 1 40); do
        local g r
        g=$(mysql_count "SELECT COUNT(*) FROM neutron.ml2_geneve_allocations;")
        r=$(mysql_count "SELECT COUNT(*) FROM neutron.ovn_hash_ring WHERE TIMESTAMPDIFF(SECOND,updated_at,NOW()) < 30;")
        [ "${g:-0}" -gt 0 ] && [ "${r:-0}" -gt 0 ] && break
        sleep 3
    done
}

discover_hosts() {
    # Map the compute host into the cell so nova can schedule (idempotent).
    [ -x "${VBIN}/nova-manage" ] || return 0
    su - stack -c "cd /opt/stack/devstack && source openrc admin admin >/dev/null 2>&1; ${VBIN}/nova-manage cell_v2 discover_hosts --verbose" 2>&1 | tail -2 || true
}

libvirt_namespaces_finalize() {
    # Cinder NFS attach: nova mounts the volume's NFS share live, but libvirt by
    # default starts qemu in its OWN (frozen) mount namespace (qemu.conf
    # namespaces=["mount"]), so qemu never sees the mount -> "Could not open ...
    # No such file". Disable the per-qemu mount namespace so qemu runs in the
    # shared namespace and sees nova's mounts. (No VMs run yet post-stack, so a
    # libvirtd restart is safe; future VMs start in the shared namespace.)
    if [ -f /etc/libvirt/qemu.conf ] && ! grep -q '^namespaces = \[\]' /etc/libvirt/qemu.conf; then
        echo "namespaces = []" >> /etc/libvirt/qemu.conf
        systemctl restart libvirtd virtqemud 2>/dev/null || true
        echo "[container-stack] disabled libvirt per-qemu mount namespace (for NFS attach)"
    fi
}

echo "[container-stack] starting stack.sh ..."
if ! run_stack; then
    echo "[container-stack] stack.sh failed; healing and retrying once..."
    heal_services
    run_stack || echo "[container-stack] WARNING: stack.sh still reported failure after heal"
fi

cinder_nfs_finalize() {
    # DevStack's nfs backend setup overwrites the [nfs] section during stack.sh,
    # leaving nas_secure_* empty (NfsDriver rejects that) and no mount options.
    # Fix it post-stack, force NFSv3, and make 'nfs' the default volume type.
    local f=/etc/cinder/cinder.conf
    [ -f "$f" ] || return 0
    python3 - "$f" <<'PY'
import configparser, sys
f = sys.argv[1]; c = configparser.ConfigParser(); c.read(f)
if c.has_section("nfs"):
    c["nfs"]["nas_secure_file_operations"] = "false"
    c["nfs"]["nas_secure_file_permissions"] = "false"
    c["nfs"]["nfs_mount_options"] = "vers=3"
c["DEFAULT"]["default_volume_type"] = "nfs"
c.write(open(f, "w"))
PY
    systemctl restart devstack@c-vol devstack@c-api 2>/dev/null || true
    echo "[container-stack] cinder NFS finalized (nas_secure=false, vers=3, default type=nfs)"
}

echo "[container-stack] ensuring compute host is discovered..."
discover_hosts
libvirt_namespaces_finalize
cinder_nfs_finalize

echo "[container-stack] DONE."
echo "[container-stack] KVM domains (run on the host's /dev/kvm):"
virsh -c qemu:///system list --all 2>/dev/null | sed 's/^/    /' || true
