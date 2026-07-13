# iSH ARM64 continuation note

The active integration uses OpenMinis' standard userspace iSH kernel with an ARM64 guest. Historical notes describing `ReleaseLinux`, `LinuxInterop`, copied native headers, or `DefaultRootPath()` are obsolete.

Current architecture, build commands, rootfs rules, verification state, and archive revisions are maintained in:

- `docs/ISH_INTEGRATION.md`
- `docs/plans/2026-07-12-ish-arm64-integration.md`

`third_party/ish` remains untouched. Runtime work belongs to `third_party/ish-arm64` and the Acode-owned adapter under `src/plugins/terminal/src/ios`.
