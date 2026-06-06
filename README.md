# gvisor-crio-installer

Run [gVisor](https://gvisor.dev) (`runsc`) sandboxes under **cri-o** on Kubernetes.

containerd supports gVisor out of the box; **cri-o does not**. This repo packages the patches plus a
one-`kubectl apply` installer that make it work — validated end-to-end on OKE (Oracle Kubernetes Engine)
cri-o 1.35.x.

> ⚠️ **Experimental.** Built from two *unmerged* upstream PRs ([gVisor #13279](https://github.com/google/gvisor/pull/13279),
> [cri-o #9974](https://github.com/cri-o/cri-o/pull/9974)). The installer **swaps the `crio` binary** on each
> node it runs on. Read the requirements before applying.

## Requirements

- **cri-o 1.35.x** and **amd64/x86_64** nodes only. The installer swaps in a patched `crio 1.35.4`; on any
  other cri-o version it would replace your crio with the wrong one. The opt-in node label below is your gate.
- A privileged DaemonSet (it writes to the host + restarts crio).

## Quickstart

```bash
# 1. Label ONLY the cri-o 1.35.x / amd64 nodes you want gVisor on:
kubectl label node <node> gvisor-crio-install=true

# 2. Apply the RuntimeClass + installer DaemonSet:
kubectl apply -f https://raw.githubusercontent.com/luccabb/gvisor-crio-installer/main/install.yaml

# 3. Verify — a runtimeClassName: gvisor pod runs under the gVisor sentry:
kubectl run gv --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"gvisor","containers":[{"name":"c","image":"busybox:1.37","command":["uname","-r"]}]}}'
kubectl logs gv   # -> 4.19.0-gvisor   (the gVisor sentry — definitive proof)
```

Then any pod opts in with `spec.runtimeClassName: gvisor`.

## How it works

The DaemonSet runs a privileged init container on each labeled node that:

1. installs `runsc` + `containerd-shim-runsc-v1` into `/usr/local/bin`,
2. writes `/etc/containerd/runsc.toml` + `/etc/crio/crio.conf.d/99-gvisor.conf` with **`runtime_type = "vm"`**,
3. backs up `/usr/bin/crio` to `crio.orig` and swaps in the patched `crio 1.35.4`,
4. restarts crio (decoupled, so it doesn't kill the installer pod).

It's **idempotent** (skips if already installed) and re-runs on every node boot, so it **self-heals** across
reboots and node replacements. Image: [`ghcr.io/luccabb/gvisor-crio-installer:1.35.4-amd64`](https://github.com/luccabb/gvisor-crio-installer/pkgs/container/gvisor-crio-installer)
(public, built by CI from this repo — see below).

## Why cri-o needs this (containerd doesn't)

cri-o's default OCI runtime path breaks gVisor three ways — the overlay rootfs never reaches the gofer, cri-o
drops the pause/infra container runsc needs, and conmon mis-monitors the sentry (wrong exit codes →
CrashLoopBackOff). It also rejects the runsc runtime at config validation. The fix is
**`runtime_type = "vm"`**, which routes runsc through cri-o's shimv2/Kata plumbing — and two upstream patches
make that path accept runsc. See [`RECIPE.md`](./RECIPE.md) for the full story.

## The patches

| repo | PR | what it does |
|---|---|---|
| gVisor | [#13279](https://github.com/google/gvisor/pull/13279) | `containerd-shim-runsc-v1` CRI-O compatibility |
| cri-o | [#9974](https://github.com/cri-o/cri-o/pull/9974) | accept the runsc-v1 shim in the `vm` path (we backported it to `release-1.35`) |

Both track [gVisor issue #10313](https://github.com/google/gvisor/issues/10313).

## How the image is built

[`.github/workflows/build-image.yml`](.github/workflows/build-image.yml) builds `runsc` + the shim (gVisor
#13279) and patched `crio` (cri-o #9974, pinned in [`installer/patches/`](./installer/patches)) **from source**
on a GitHub runner and publishes the image to GHCR **on every `v*` tag** — reproducible from the repo, no
manual artifacts. To build it yourself, put the amd64 binaries in `installer/out/` and:

```bash
cd installer
docker buildx build --platform linux/amd64 -t <your-namespace>/gvisor-crio-installer:1.35.4-amd64 --push .
```

Building the binaries (and the amd64 gotchas) is documented in [`RECIPE.md`](./RECIPE.md).

## Other cri-o versions / arm64

This image pins **cri-o 1.35.x amd64**. For another version, backport cri-o #9974 to *that* release branch and
rebuild; for arm64, build all three binaries for arm64. The recipe covers both.

## The durable alternative: node image

The DaemonSet does a live binary swap. The cleaner end-state for a fleet is to **bake** runsc + shim +
patched crio + the config into your **node image**, so nodes boot gVisor-ready with no swap. The DaemonSet is
the works-today path; the node image is the production one. (And once #13279 + #9974 merge upstream, none of
this is needed — gVisor-on-cri-o becomes as simple as it already is on containerd.)

## License

Apache-2.0. The bundled binaries (gVisor, cri-o) are Apache-2.0.
