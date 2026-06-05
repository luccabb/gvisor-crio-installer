#!/usr/bin/env bash
# Runs in the gvisor-installer DaemonSet init container: privileged, hostPID, host / mounted at /host.
# Installs the patched gVisor-on-cri-o stack (runsc + shim + crio 1.35.4 + vm-path config) on the node.
# Idempotent — re-runs harmlessly on every node boot (DaemonSet semantics), so it self-heals.
set -euo pipefail
SRC=/opt/gvisor-install
NS="nsenter -t 1 -m -u -i -n -p --"

if $NS crio --version 2>/dev/null | grep -q '1\.35\.4' \
   && grep -q 'runtime_type *= *"vm"' /host/etc/crio/crio.conf.d/99-gvisor.conf 2>/dev/null \
   && [ -x /host/usr/local/bin/containerd-shim-runsc-v1 ]; then
  echo "already installed (crio 1.35.4 + vm-path runsc) — skipping"
  exit 0
fi

echo ">>> install runsc + shim"
install -m0755 "$SRC/runsc" /host/usr/local/bin/runsc
install -m0755 "$SRC/containerd-shim-runsc-v1" /host/usr/local/bin/containerd-shim-runsc-v1

echo ">>> write vm-path config"
mkdir -p /host/etc/containerd /host/var/log/runsc /host/etc/crio/crio.conf.d
cat > /host/etc/containerd/runsc.toml <<'TOML'
binary_name = "/usr/local/bin/runsc"
grouping = true
[runsc_config]
  platform = "systrap"
  network  = "sandbox"
TOML
cat > /host/etc/crio/crio.conf.d/99-gvisor.conf <<'CONF'
[crio.runtime]
selinux = false
[crio.runtime.runtimes.runsc]
runtime_path        = "/usr/local/bin/containerd-shim-runsc-v1"
runtime_config_path = "/etc/containerd/runsc.toml"
runtime_type        = "vm"
runtime_root        = "/run/runsc"
CONF

echo ">>> swap crio binary -> 1.35.4 (keep .orig once)"
CRIO=$($NS bash -c 'command -v crio')
$NS bash -c "[ -f ${CRIO}.orig ] || cp -a ${CRIO} ${CRIO}.orig"
install -m0755 "$SRC/crio" "/host${CRIO}"
echo ">>> now: $($NS crio --version | head -1)"

echo ">>> restart crio decoupled from this pod"
$NS systemd-run --no-block --collect --unit=gv-crio-restart systemctl restart crio
echo "INSTALL_DONE"
