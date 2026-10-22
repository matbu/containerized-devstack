# containerized-devstack: a systemd-enabled Ubuntu 24.04 (Noble) container that runs
# DevStack. Ubuntu is DevStack's primary, CI-tested platform and ships Python
# 3.12 natively, so the whole stack installs cleanly without Python-version
# gymnastics. The container runs its own libvirtd; VMs execute on the host's
# KVM via the passed-through /dev/kvm (identical performance to host libvirt).
FROM docker.io/library/ubuntu:24.04

ARG DEVSTACK_BRANCH=stable/2026.2
ENV container=podman DEBIAN_FRONTEND=noninteractive

# systemd (DevStack runs services as systemd units) + the few base tools
# DevStack assumes present. DevStack installs libvirt/qemu/ovn/etc. itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        sudo git ca-certificates curl rsync gettext-base locales \
        lsb-release software-properties-common \
        python3 python3-venv python3-dev \
        iproute2 iptables ebtables kmod net-tools iputils-ping \
        nfs-kernel-server nfs-common rpcbind \
    && locale-gen en_US.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Trim systemd units that make no sense in a container.
RUN find /etc/systemd/system /lib/systemd/system \
        -path '*getty.target*' -prune -o -name '*.wants' -prune 2>/dev/null; \
    systemctl mask \
        systemd-logind.service console-getty.service getty.target \
        systemd-udevd.service systemd-udev-trigger.service \
        dev-hugepages.mount sys-fs-fuse-connections.mount \
        || true

# DevStack refuses to run as root; create the conventional 'stack' user.
RUN useradd -s /bin/bash -d /opt/stack -m stack \
    && chmod 0755 /opt/stack \
    && echo "stack ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/stack \
    && chmod 440 /etc/sudoers.d/stack

# Pin the DevStack checkout at build time (branch is an ARG).
RUN git clone --depth 1 --branch "${DEVSTACK_BRANCH}" \
        https://opendev.org/openstack/devstack /opt/stack/devstack \
    && chown -R stack:stack /opt/stack

# local.conf template (rendered at run time) + the in-container driver script.
COPY local.conf.tmpl /opt/stack/local.conf.tmpl
COPY scripts/ovn-wait.inc /opt/stack/ovn-wait.inc
COPY scripts/container-stack.sh /usr/local/bin/container-stack.sh
RUN chmod +x /usr/local/bin/container-stack.sh

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
