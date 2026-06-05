# Recipe: gVisor on cri-o

How to make gVisor (`runsc`) actually run under **cri-o** (it doesn't, out of the box). Validated end-to-end
on OKE cri-o 1.35.x (amd64). containerd supports gVisor natively; cri-o needs everything below.

---

## 0. Why stock cri-o can't run gVisor

cri-o's **default OCI runtime path** breaks gVisor three ways:
1. the container's overlay **rootfs never reaches the gofer** → `failed to load /bin/busybox`;
2. cri-o drops the **pause/infra container** (`drop_infra_ctr=true`) that gVisor needs → `cannot load sandbox`;
3. cri-o monitors containers via **conmon**, which assumes the runtime spawns a waitable child — gVisor runs it
   in its userspace kernel → wrong exit codes → CrashLoopBackOff.

cri-o also **rejects the runsc runtime at config validation**: `containerd binary naming pattern is not
followed` (the v1 shim isn't named `…-v2`).

**The fix:** set `runtime_type = "vm"` so runsc rides cri-o's **shimv2/Kata** plumbing instead — it keeps the
infra container, uses shimv2 monitoring (no conmon bug), and accepts `containerd-shim-runsc-v1`. Two upstream
patches make that path work with runsc.

---

## 1. The two upstream PRs (this is the "draft PRs" answer)

Both are **xw19's**, both **OPEN/unmerged**, tracking gVisor issue **#10313**, branch `issue/gvisor/10313`:

| repo | PR | what it does | targets |
|---|---|---|---|
| gVisor | **#13279** | `containerd-shim-runsc-v1` CRI-O compat: `resolveGrouping()` falls back to CRI-O's `io.kubernetes.cri-o.SandboxID` so sub-containers attach to the pause shim; `forward()` turns a panic on the missing containerd event address into a warning | gVisor master |
| cri-o | **#9974** | accept the `runsc-v1` shim in the `vm` runtime path: regex change + parse the shim's JSON `BootstrapParams` stdout | cri-o **main (~1.37)** |

### Which draft PRs *you* need
- **gVisor: none of your own.** #13279 is already open, CLA-clean, CI-green. Don't duplicate it — **track it**
  (or carry xw19's commit `d47188a8215e` on a fork branch pinned by your build). It merges via Copybara on
  Google's schedule; don't block on it.
- **cri-o on main / ≥1.37:** just need #9974 (+ #13279). Carry until merged.
- **cri-o on 1.35.x (e.g. OKE):** #9974 is main-only, so you need a **release-1.35 backport of #9974** — that's
  **our draft PR**, staged at `luccabb/cri-o` branch `runsc-v1-backport-release-1.35` (commit `2abbe23`).
  It's upstream #9974's exact diff and **applies cleanly** to `release-1.35`. cri-o's process is
  merge-to-main-then-cherry-pick, so only *send* it upstream after #9974 merges; until then carry it in your build.

### The cri-o #9974 change (so you can reproduce it)
Two source files (+ their tests):
- **`pkg/config/config.go`** — accept the runsc-v1 shim name:
  ```diff
  - RuntimeTypeVMBinaryPattern = "containerd-shim-([a-zA-Z0-9\\-\\+])+-v2"
  + // runsc (gVisor) uses the v1 shim; all other VM runtimes are expected to use v2.
  + RuntimeTypeVMBinaryPattern = "containerd-shim-(runsc-v1|([a-zA-Z0-9\\-\\+])+-v2)"
  ```
- **`internal/oci/runtime_vm.go`** — parse the shim's JSON bootstrap output (modern shims, incl. runsc-v1,
  emit a JSON `BootstrapParams` on stdout; legacy shims emit a bare address):
  ```go
  func ParseShimAddress(out []byte) (string, error) {
      address := strings.TrimSpace(string(out))
      if strings.HasPrefix(address, "{") {
          var params client.BootstrapParams   // github.com/containerd/containerd/runtime/v2/shim, aliased `client`
          if err := json.Unmarshal(out, &params); err != nil {
              return "", fmt.Errorf("parse shim bootstrap params %q: %w", address, err)
          }
          address = params.Address
      }
      return address, nil
  }
  // …and startRuntimeDaemon uses `address, err := ParseShimAddress(out)` instead of strings.TrimSpace(string(out))
  ```
  (`client.BootstrapParams` exists in release-1.35's vendored containerd v1.7.29 — use it, don't reinvent a
  local struct.)

---

## 2. Build the binaries

You need three amd64 binaries: `runsc`, `containerd-shim-runsc-v1`, and patched `crio`.

### runsc + shim (gVisor #13279, via bazel)
```bash
git clone --depth 1 -b issue/gvisor/10313 https://github.com/xw19/gvisor.git && cd gvisor
bazel build --jobs=16 //runsc //shim:containerd-shim-runsc-v1
# outputs under bazel-bin/ (follow the symlinks: find -L bazel-bin -name runsc -type f)
```
**amd64 build deps** (beyond a normal toolchain — these bite specifically on amd64):
- `gcc-aarch64-linux-gnu g++-aarch64-linux-gnu` — gVisor's `//vdso` genrule builds the vdso for **both** arches.
- `libc6-dev-i386` — the eBPF/XDP genrule (`//tools/xdp/cmd/bpf:redirect_host_ebpf`, a `runsc` dep) needs
  `gnu/stubs-32.h`.
- plus `build-essential gcc-x86-64-linux-gnu g++-x86-64-linux-gnu clang llvm libbpf-dev` + bazelisk.

### crio (release-1.35 + #9974, via go)
```bash
git clone --depth 1 -b release-1.35 https://github.com/cri-o/cri-o.git && cd cri-o
git apply 9974.diff          # `gh pr diff 9974 -R cri-o/cri-o > 9974.diff` — applies cleanly to release-1.35
make bin/crio bin/pinns
```
Deps: `go1.23.4`, `pkg-config libseccomp-dev libgpgme-dev libassuan-dev libdevmapper-dev libbtrfs-dev`.

> Build on amd64 natively. Cross-building amd64 under qemu on an arm Mac **segfaults** the Go/bazel binaries —
> build in an amd64 pod/VM/CI instead. (A COPY-only Docker image of prebuilt binaries cross-builds fine.)

---

## 3. Configure the node

`/etc/containerd/runsc.toml`
```toml
binary_name = "/usr/local/bin/runsc"
grouping = true                 # sub-containers attach to the pause container's sandbox shim
[runsc_config]
  platform = "systrap"
  network  = "sandbox"
```

`/etc/crio/crio.conf.d/99-gvisor.conf`
```toml
[crio.runtime]
selinux = false
[crio.runtime.runtimes.runsc]
runtime_path        = "/usr/local/bin/containerd-shim-runsc-v1"
runtime_config_path = "/etc/containerd/runsc.toml"
runtime_type        = "vm"      # ← the crux: route runsc through the shimv2/Kata path
runtime_root        = "/run/runsc"
```
Do **NOT** use `skip_mount_home` or the OCI path — that combination corrupted node storage in earlier attempts.

---

## 4. Install on the node

```bash
install -m0755 runsc                     /usr/local/bin/runsc
install -m0755 containerd-shim-runsc-v1  /usr/local/bin/containerd-shim-runsc-v1
# write the two config files above
cp -a /usr/bin/crio /usr/bin/crio.orig   # back up the stock binary once
install -m0755 crio /usr/bin/crio        # swap in the patched 1.35.4
systemctl restart crio
```
Idempotency check: skip if `crio --version` is already the patched build AND `99-gvisor.conf` has
`runtime_type = "vm"` AND the shim is present.

**At scale:** package the three binaries + this script into an installer image and run it as a privileged,
`hostPID` DaemonSet (init `nsenter`s to the host; restart crio via `systemd-run --no-block` so it doesn't kill
the installer pod). It's idempotent and re-runs on boot, so it self-heals. **Durable end-state:** bake the
binaries + configs into the node image so nodes boot ready — no live binary swap.

---

## 5. Kubernetes wiring

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata: { name: gvisor }
handler: runsc
```
Then any pod opts in with `spec.runtimeClassName: gvisor`. (Optionally add `scheduling.nodeSelector` to the
RuntimeClass so gVisor pods only land on gVisor-ready nodes.)

---

## 6. Verify

```bash
kubectl run gv --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"gvisor","containers":[{"name":"c","image":"busybox:1.37","command":["sh","-c","uname -r; sleep 5"]}]}}'
kubectl logs gv   # → 4.19.0-gvisor   ← the gVisor sentry; definitive proof
```
Also worth checking inside the sandbox: DNS, in-cluster TCP, and egress all work under `network=sandbox`.

---

## Version matrix

| your cri-o | what you need |
|---|---|
| main / ≥1.37 | gVisor #13279 + cri-o #9974 (carry both until merged) |
| 1.35.x (OKE) | gVisor #13279 + **release-1.35 backport of #9974** (`luccabb/cri-o@runsc-v1-backport-release-1.35`) |

Links: gVisor PR https://github.com/google/gvisor/pull/13279 · cri-o PR https://github.com/cri-o/cri-o/pull/9974
· tracking issue https://github.com/google/gvisor/issues/10313
