# OpenSC 0.26.1 + ePass2003 + MoldSign (macOS) Fix Handoff

## One-Line Installer (Recommended)

For users that already have MoldSign installed but signing fails/loops, run:

```bash
curl -fsSL https://raw.githubusercontent.com/CristianProdius/molding-fix-for-Mac/main/scripts/fix-moldsign-libcastle.sh | bash
```

What it does:
1. **Downloads & deploys patched x86_64 binaries** from the GitHub Release into MoldSign's `native_lib/` (with automatic backup).
2. **Configures `PKCS11.properties`** for single-provider mode (`driver_lib=libcastle.1.0.0.dylib`).
3. **Restarts MoldSign** Server/Desktop (Server first).
4. **Prints verification** — binary architectures, config, and log checks.

### Deployed Binaries

| File | Size | Description |
|------|------|-------------|
| `opensc-pkcs11.so` | 228 KB | PKCS#11 module (patched: SM crash fix + ePass2003 PKCS#15 emulator) |
| `libopensc.12.dylib` | 1.8 MB | OpenSC core library |
| `libcrypto.3.dylib` | 4.7 MB | OpenSSL 3 (x86_64 build) |
| `ossl-modules/legacy.dylib` | 111 KB | OpenSSL legacy provider (DES for SCP01 SM) |

### Flags

| Flag | Effect |
|------|--------|
| `--no-restart` | Apply fixes but don't restart MoldSign apps |
| `--config-only` | Only apply PKCS11.properties config fix, skip binary deployment |

Examples:

```bash
# Full fix without restarting
curl -fsSL https://raw.githubusercontent.com/CristianProdius/molding-fix-for-Mac/main/scripts/fix-moldsign-libcastle.sh | bash -s -- --no-restart

# Config-only fix (if binaries are already deployed)
curl -fsSL https://raw.githubusercontent.com/CristianProdius/molding-fix-for-Mac/main/scripts/fix-moldsign-libcastle.sh | bash -s -- --config-only
```

## Releases

| Version | Date | Description |
|---------|------|-------------|
| [v1.0.0](https://github.com/CristianProdius/molding-fix-for-Mac/releases/tag/v1.0.0) | 2026-03-09 | Full MoldSign ePass2003 fix — patched OpenSC/OpenSSL x86_64 binaries + config |

## Problem Summary
MoldSign could not use STISC ePass2003 reliably due to multiple stacked issues:

1. Crash in OpenSC SM path (NULL APDU dereference).
2. Card not exposed as PKCS#15 because ePass2003 uses proprietary ENTERSAFE FS layout.
3. DES-based SM (SCP01) failed under OpenSSL 3 when legacy provider was not reachable from OpenSC's non-default `OSSL_LIB_CTX`.
4. Additional runtime blocker: MoldSign is `x86_64`, but deployed OpenSC/OpenSSL libs were `arm64` at one point (`incompatible architecture`).

## What Was Fixed

### A) Crash fix + defensive guards
- `src/libopensc/card-epass2003.c`
  - Preserve real error from `epass2003_sm_wrap_apdu()` and do not overwrite it with `SC_SUCCESS` from cleanup.
- `src/libopensc/sm.c`
  - Add `sm_apdu == NULL` guard before `sc_check_apdu()`.
- `src/libopensc/apdu.c`
  - Add defensive `NULL` check in `sc_check_apdu()`.

Patch: `patches/0001-epass2003-sm-crash-and-null-guards.patch`

### B) PKCS#15 emulation for ENTERSAFE layout
- New emulator: `src/libopensc/pkcs15-epass2003.c`
  - Detect ENTERSAFE index markers.
  - Build token info.
  - Add PIN object.
  - Extract cert from proprietary file.
  - Add explicit RSA public key object (`Public Key`) derived from cert to avoid cert-generated alias collisions in PKCS#11 providers.
  - Keep private key label aligned with certificate label (`Certificate`) for MoldSign alias resolution path.
- Registration/build wiring:
  - `src/libopensc/pkcs15-syn.c`
  - `src/libopensc/pkcs15-syn.h`
  - `src/libopensc/Makefile.am`

Patches:
- `patches/0002-epass2003-pkcs15-emulator-registration.patch`
- `patches/0002a-epass2003-pkcs15-emulator-new-file.patch`

### C) OpenSSL 3 legacy/provider robustness
- `src/libopensc/ctx.c`
  - Add `sc_openssl3_set_provider_search_path()`.
  - Resolve loaded `libcrypto` path via `dladdr(OpenSSL_version_num, ...)`.
  - Set provider search path to sibling `ossl-modules` directory in OpenSC's non-default libctx.
- `src/libopensc/sc-ossl-compat.h`
  - Add fallback fetch for digest/cipher from process-global OpenSSL context (`NULL`) only if private libctx fetch fails and private legacy provider is unavailable.

Patch: `patches/0003-openssl3-provider-searchpath-and-libctx-fallback.patch`

## Runtime Packaging Fix Used in MoldSign

The deployed MoldSign runtime now uses:
- `x86_64` OpenSC/OpenSSL libraries (matching MoldSign app architecture).
- Local linkage (`@loader_path` / `@rpath`) so `opensc-pkcs11.so`, `libopensc.12.dylib`, `libcrypto.3.dylib`, and `ossl-modules/legacy.dylib` resolve consistently in bundle layout.
- `PKCS11.properties` default driver path set to MoldSign `native_lib`.

Current production-stable configuration (validated on 2026-03-09) is single-provider:
- `driver_lib=libcastle.1.0.0.dylib`

Reason:
- Multi-provider mode (`opensc + castle + others`) can expose duplicate certificate entries for the same token in MoldSign and trigger PIN retry loops on the OpenSC path (`PrivateKey not found`), while `libcastle` signs successfully.

Runtime snapshots are in `runtime/`.


## MoldSign Paths Used

- Runtime libs: `/Applications/STISC/MoldSign/native_lib`
- Driver config: `/Applications/STISC/MoldSign/MoldSignData/Server/PKCS11.properties`
- Logs: `/Applications/STISC/MoldSign/log/err_MoldSign_Server.log`

## Backup

Before runtime replacement, backup was created at:
- `/Applications/STISC/MoldSign/native_lib/backup-20260302-235646`

## Notes for Upstream Investigation

- The OpenSC source patches are intended for reproducible investigation and potential upstreaming.
- The runtime x86_64 packaging adjustments are deployment-specific but included here because they were necessary for MoldSign to load the module correctly on macOS.
- Do not patch MoldSign signed JAR classes in-place (`ClientCardServer-2.0.jar`): JVM package signer checks will raise `SecurityException` ("signer information does not match") and break PIN dialog loading.
