FROM ubuntu:22.04
LABEL org.opencontainers.image.source=https://github.com/luccabb/gvisor-crio-installer
LABEL org.opencontainers.image.description="Installs gVisor (runsc) on cri-o 1.35.x amd64 nodes"
LABEL org.opencontainers.image.licenses=Apache-2.0
# COPY-only (no RUN) so this cross-builds for amd64 from any host without qemu.
# util-linux (nsenter) + bash + coreutils are already in the base image.
COPY out/runsc out/containerd-shim-runsc-v1 out/crio out/pinns /opt/gvisor-install/
COPY node-install.sh /opt/gvisor-install/install.sh
