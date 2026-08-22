# JIT enablement investigation (JSC/Bun under iSH-A64)

Status: **blocked on emulator architecture** — documented for future work.
Default remains `JSC_useJIT=false` (kernel-injected).

## Symptom matrix (all verified empirically)

| Configuration | Result |
|---|---|
| bun 1.3.14 / 1.4.0 stable, JIT off | ✅ correct, stable |
| bun 1.4.0 stable, JIT **on**, pure compute (`fib`, string, 50k-key object) | ⚠️ compute runs (787ms stats print) but **console output lost**, then SIGSEGV |
| bun 1.4.0 stable, JIT on + explicit `process.exit(0)` | ❌ SIGSEGV immediately at first output |
| opencode v1/v2 with JIT on | ❌ slow (192s) + silently empty output |
| Node/V8 | historically required `--jitless` (pre-existing injection) |

## Evidence

- Crash is `SIGSEGV at address 0x8` during/after the first `write(1,…)` issued
  from JIT'd guest code; pure computation completes correctly before it.
- `process_vm_readv` stub messages come from Bun's crash dumper (post-crash).
- Fork comments already document the class: signals are delivered at JIT
  *gadget boundaries* (imprecise PC), and "V8 code generation incompatible
  with our JIT" (scope corruption). Same class hits JSC.

## Root-cause hypothesis

Foreign JITs (V8/JSC) emit guest code into RWX pages and patch it constantly.
The emulator's pipeline assumes static-ish code:

1. **SMC invalidation gap**: `asbestos_invalidate_page` is called from
   `memory.c` unmap/COW/fault paths only. Writes through the TLB fast path to
   an already-writable page containing compiled blocks do NOT invalidate —
   stale host translations execute.
2. **Imprecise faults**: faults raised inside translated blocks retry at block
   boundaries; documented SP-compounding hazard makes any fix here delicate.
3. Possible additional issue: JIT'd guest code using instruction patterns the
   decoder mis-executes (would corrupt registers → garbage values like
   `e = 1.36e-303` seen in opencode boots even with JIT off — separate bug,
   see git log for futex/stack fixes that resolved other instances).

## Candidate fixes (ranked)

1. **Page-block gate**: expose `asbestos_page_has_blocks(page)`; suppress
   `page_if_writable` caching in `tlb_handle_miss` for such pages so writes
   fall through to the fault path which already invalidates (memory.c:927).
   Medium effort; needs care around the documented INT_GPF retry hazards.
2. Precise fault context delivery (PC relocation within blocks). Hard.
3. Upstream: coordinate with iSH-A64 fork author; V8/JSC vendors won't change.

## Reproduction

```sh
ISH_BIN=third_party/ish-arm64/build-host-arm64/ish
ROOTFS=<rootfs>   # needs bun-linux-aarch64-musl under /opt/bun
env ISH_GUEST_CPU_COUNT=1 "$ISH_BIN" -f "$ROOTFS" -d /home/acode /bin/sh -c '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
JSC_useJIT=true /opt/bun/bun-linux-aarch64-musl/bun -e \
  "function f(n){return n<2?n:f(n-1)+f(n-2)}; console.log(f(20))"'
# → banner prints, no fib20 output, Segmentation fault
```
