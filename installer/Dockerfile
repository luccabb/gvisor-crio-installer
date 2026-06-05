FROM ubuntu:22.04
# COPY-only (no RUN) so this cross-builds for amd64 from any host without qemu.
# util-linux (nsenter) + bash + coreutils are already in the base image.
COPY out/runsc out/containerd-shim-runsc-v1 out/crio out/pinns /opt/gvisor-install/
COPY node-install.sh /opt/gvisor-install/install.sh
