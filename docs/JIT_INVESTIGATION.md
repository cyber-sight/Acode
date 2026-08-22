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

0. **Intercept `ic ivau` / `dc cvau` (QEMU-for-RISC insight) — CHEAPEST & PRECISE.**
   On ARM64, correct JITs (JSC, V8) explicitly execute `ic ivau` (+`dc cvau`,
   `dsb`, `isb`) after emitting code — `__builtin___clear_cache`. Real kernels
   trap/handle these; hardware does NOT snoop I-cache vs D-cache. The emulator
   can therefore treat execution of `IC IVAU` by guest code as an exact SMC
   signal: decode the cache-maintenance instruction and call
   `asbestos_invalidate_range(page(va), …)` before continuing. No page
   protection, no fault delivery needed, zero cost outside codegen moments.
   Requires locating the system-instruction path in the decoder/gadget layer
   (`decode.h` classifies "101x - Branches, exceptions, system"; current grep
   shows NO ivau handling → likely silently ignored today).

1. **QEMU-style page protection** (user-mode TCG scheme): when a block is
   generated covering page P, mprotect P read-only on the host; any write
   faults natively → handler invalidates blocks in P, unprotects, retries the
   store. Refinement for mixed code/data pages: per-page bitmap of code ranges
   so only stores hitting actual code invalidate (QEMU does exactly this when
   a page invalidates "too often"). Medium effort; needs care around the
   documented INT_GPF retry hazards.

1b. **Page-block gate** (earlier idea): suppress writable-TLB caching for
    pages containing blocks — weaker variant of #1 without host mprotect.
2. **Precise fault-context delivery**: maintain host-PC→guest-PC maps per
   block (QEMU: "keeps a map from host program counter to target program
   counter… looks up where the exception happened"); store per-instruction
   guest-PC at potentially-faulting ops (loads/stores/syscalls) so guest
   signal frames get exact PC. Required anyway for V8/JSC GC write-barriers,
   which rely on SIGSEGV-with-context against protected heap pages.
3. Upstream: coordinate with iSH-A64 fork author; V8/JSC vendors won't change.

## QEMU reference design (verified against qemu docs, devel/tcg.rst)

- **SMC (user-mode)**: mprotect host page RO when a TB is generated in it;
  write → host SEGV → invalidate all TBs in that page (per-page TB linked
  list) → unprotect → retry store. Soft-MMU refinement: code-range bitmap
  per hot page; stores check bitmap first.
- **Precise exceptions**: host-SIGSEGV handler maps host PC → target
  instruction via per-TB saved opcode positions ("restore_state_to_opc");
  longjmp out of generated code; CPU state flushed per instruction where
  needed.
- **RISC targets**: correct software uses explicit barriers/cache flushes —
  hence candidate #0 above is the natural hook on arm64.
- Chaining only within same page; TBs keyed by physical address under
  softmmu.

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

## Follow-up isolation (round 2)

| Probe (JSC_useJIT=true) | Result |
|---|---|
| `console.log("hi")` only | ✅ works |
| 3M-iteration int loop (`x=(x+i)%97`) | ✅ correct — fully JIT'd hot loop |
| 2000× string concat (GC churn) | ✅ correct |
| **recursive `fib(20)`** | ❌ SIGSEGV at 0x8, output lost |

→ Bug is specific to **recursive optimized frames**, not GC/strings/scale.
Prime suspect: the documented INT_GPF retry hazard — a fault inside a
translated block retries from block start, re-executing stack-check prologue
`sub sp, sp, #N` and compounding SP; recursive self-calls hammer exactly the
stack-growth/check paths. memory.c fixed one instance (growsdown trylock);
other fault paths may retain the flaw.

### Round-2 instrumentation plan

1. printk in every fault path that can hit during fib: growsdown, COW,
   invalidate_page, plus INT_GPF retry entry — tagged with guest PC.
2. Run crashing fib under instrumentation; the last path logged before death
   identifies the failing mechanism.
3. If retry-compounding confirmed: make fault-retry safe for prologue
   instructions (e.g., checkpoint original SP at block entry, restore on
   retry) — this is ALSO the prerequisite for precise-context delivery (#2),
   since exact PC requires exactly-once execution semantics.
4. Then implement ic-ivau interception (#0) so JSC codegen invalidations are
   honored, and re-test the full matrix with JIT on.
