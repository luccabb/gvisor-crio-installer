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

Post install, you should be able to ssh to nodes and see:
```
$ crio --version
crio version 1.35.4
  ...
$ runsc --version
runsc version d47188a8215e
spec: 1.2.1
```

## License
Apache-2.0
