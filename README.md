# gvisor-crio-installer

One `kubectl apply` to run [gVisor](https://gvisor.dev) (`runsc`) sandboxes under **cri-o**. containerd
supports gVisor out of the box; cri-o doesn't — this installs the patched runtime that makes it work.

> ⚠️ **cri-o 1.35.x + amd64 nodes only** (the installer swaps in a patched `crio 1.35.4`). Experimental —
> built from unmerged [gVisor #13279](https://github.com/google/gvisor/pull/13279) +
> [cri-o #9974](https://github.com/cri-o/cri-o/pull/9974).

## Install

```bash
kubectl label node <node> gvisor-crio-install=true        # cri-o 1.35.x amd64 nodes you want gVisor on
kubectl apply -f https://raw.githubusercontent.com/luccabb/gvisor-crio-installer/main/install.yaml
```

Verify: a pod with `runtimeClassName: gvisor` reports `uname -r` = `4.19.0-gvisor`.

A privileged DaemonSet installs `runsc` + the patched `crio` on each labeled node and switches cri-o to the
`runtime_type="vm"` path (idempotent, self-heals on reboot). Image `ghcr.io/luccabb/gvisor-crio-installer`,
built from source by [CI](.github/workflows/build-image.yml) — see [`installer/`](./installer).

## License
Apache-2.0
