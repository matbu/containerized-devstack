# containerized-devstack

Run **DevStack / OpenStack inside a podman container**, with **nova using the
host's KVM as the hypervisor** (hardware acceleration via `/dev/kvm`) and **all
VM storage on the host**. The container is fully self-contained — it runs its
own networking in an isolated namespace, so it coexists with other workloads on
the host without touching their networking.

```
          ┌──────────────────────── podman host (the hypervisor) ───────────────────────┐
          │                                                                              │
          │  other host workloads (untouched)                                            │
          │                                                                              │
          │  ┌─ container: devstack (own netns, 172.31.0.10) ────────────────────┐        │
          │  │  keystone glance nova neutron(OVN) placement cinder horizon        │        │
          │  │  mysql rabbitmq  +  libvirtd + ovn/ovs (all private to this netns) │        │
          │  │                                                                   │        │
          │  │  guest VMs ── qemu ──►  /dev/kvm  (host CPU, hardware accel) ──────┼──► host │
          │  │            └─ disks ─►  host data dir (bind-mount) ────────────────┼──► host │
          │  └───────────────────────────────────────────────────────────────────┘        │
          └──────────────────────────────────────────────────────────────────────────────┘
```

* **Control plane + libvirt in the container.** All OpenStack services *and*
  libvirtd run inside an Ubuntu 24.04 systemd container (DevStack's primary,
  CI-tested platform; ships Python 3.12 natively).
* **Hypervisor = the host's KVM.** qemu opens the passed-through `/dev/kvm`, so
  guest vCPUs run directly on the host's physical cores (VT-x). With
  `cpu_mode=host-passthrough` the guest sees the host CPU model. **Performance
  is identical to running libvirt on the host** — the container is just
  namespaces around the qemu process, no nesting.
* **Storage on host.** The DevStack data dir (nova instances, glance, cinder)
  lives on the host and is bind-mounted into the container at `/opt/stack/data`.
* **Isolated networking.** DevStack's default ML2/**OVN** runs inside the
  container's **own network namespace** (the container is *not* `--network
  host`), on a dedicated podman network (`172.31.0.0/24`). Services bind to the
  container's own IP, avoiding host port clashes.

## Design notes

* The container keeps everything (OVN/OVS, libvirtd, databases, APIs) private to
  its own namespace, so it can run alongside other services on the same host.
* VMs are managed through the container's libvirt (`podman exec … virsh`), while
  the qemu processes run on the host's KVM.
* Latest stable OpenStack is used on the Ubuntu base (tunable via
  `DEVSTACK_BRANCH`).

Everything is tunable in [`config.env`](./config.env).

## Usage

```bash
# one shot: sync -> prep host -> build -> start container -> stack -> route -> info
./run.sh all            # or: make all

# individual phases
./run.sh prep           # podman network + data dir + kernel modules
./run.sh build          # build the image
./run.sh up             # (re)create the systemd container on the podman net
./run.sh stack          # run DevStack (long: ~20-40 min)
./run.sh route          # host route to floating range (reach VM FIPs)
./run.sh info           # print access URLs / credentials

# operate
./run.sh logs           # tail stack.sh.log
./run.sh shell          # root shell in the container
./run.sh push           # tag + push the image to the registry
./run.sh destroy        # remove container (keeps network + data)
./run.sh nuke           # remove everything incl. data + network + route
```

### Remote or local

The same commands work whether you drive a remote host over SSH or run directly
on the target machine:

```bash
# Remote (over ssh) — the default:
LAB_HOST=root@myhost ./run.sh all       # or: make all LAB_HOST=root@myhost

# Local — on this machine, or when you're already logged into the server:
LAB_HOST=local ./run.sh all             # or: PDS_LOCAL=1 ./run.sh all
```

(You can also set `LAB_HOST` once in `config.env`.)

In local mode there's no ssh/rsync: podman, systemctl and networking run
directly, and `sync` is a no-op when you run from the project directory. Local
mode needs privileges for podman/systemctl/ip (run as root or with rootful
podman). The host must be Linux with `/dev/kvm` (KVM is required for the VMs).

### Reaching the dashboard / APIs

Services bind to the container IP `172.31.0.10`, reachable from the host. From
your workstation, tunnel through the host:

```bash
ssh -L 8080:172.31.0.10:80 -L 5000:172.31.0.10:5000 root@<host>
# Horizon: http://localhost:8080/dashboard   (admin / <ADMIN_PASSWORD>)
```

### Where are the VMs?

```bash
ssh root@<host> "podman exec devstack virsh -c qemu:///system list --all"
```

They run on the host's KVM; their disks live under the host data dir
(`/opt/stack/data/nova/instances` inside the container).

## Files

| file | purpose |
|------|---------|
| `config.env` | all tunables (host, branch, IPs, ranges, paths) |
| `Containerfile` | Ubuntu 24.04 + systemd + DevStack checkout |
| `local.conf.tmpl` | DevStack config template (rendered at run time) |
| `scripts/host-prep.sh` | podman network + dir + modules (runs on the host) |
| `scripts/container-stack.sh` | in-container: render config + run stack.sh |
| `run.sh` / `Makefile` | orchestration from your workstation |

## Caveats

* Pinned branch **`stable/2026.2`** (tunable via `DEVSTACK_BRANCH`).
* **Cinder** uses an **NFS backend** (not LVM/iSCSI): iSCSI can't work because
  `iscsid` can't reach the kernel iSCSI netlink from the container's isolated
  network namespace. An in-container NFS server exports a dir on the host; cinder
  and nova mount it (NFSv3), so both volume *create* and *attach* work. Two
  enablers are handled automatically: nova/cinder `nfs_mount_options = vers=3`
  (the loopback export only serves v3 cleanly) and libvirt
  `qemu.conf namespaces = []` (so qemu sees nova's live NFS mounts).
* nova reports the host's full CPU/RAM as capacity — fine for dev/test, not for
  production scheduling.
* Re-run `./run.sh prep` + `./run.sh route` after a host reboot (the podman
  network is persistent, but the floating-range route and modules are runtime
  state).
