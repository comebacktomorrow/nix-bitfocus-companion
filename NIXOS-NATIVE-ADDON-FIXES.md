# NixOS Native Addon Fixes for Bitfocus Companion

This document explains three runtime issues that must be addressed when running
Bitfocus Companion on NixOS, particularly when surface modules with native
(compiled) Node.js addons are installed — such as `mirabox-stream-dock`.

---

## Background

Companion manages surface devices (Stream Decks, Mirabox docks, etc.) by
spawning each surface module as a **child process** via Node.js IPC:

```javascript
spawn(node, ['SurfaceThread.js'], {
  stdio: ['pipe', 'pipe', 'pipe', 'ipc'],
  env: { MODULE_ENTRYPOINT, MODULE_MANIFEST, VERIFICATION_TOKEN, HOME },
  cwd: <module directory>,
})
```

The child process receives a minimal environment. Crucially, `LD_LIBRARY_PATH`
is **not** inherited. Surface modules that ship prebuilt `.node` native addons
must therefore be able to locate their shared library dependencies through other
means.

---

## Fix 1 — RPATH: native addons can't find system libraries

### Symptom

Surface modules that use native addons (e.g. `libusb`, `libudev`, `libstdc++`)
fail to start. On NixOS all shared libraries live in `/nix/store/…`, and
because `LD_LIBRARY_PATH` is not passed to child processes, `dlopen` cannot
find them.

### Root cause

NixOS does not populate `/usr/lib` or `/lib`. Prebuilt `.node` files from npm
packages have no RPATH baked in and rely on the conventional `LD_LIBRARY_PATH`
approach, which companion's child-process spawn does not support.

### Fix

Use `patchelf --set-rpath` to bake the Nix store library paths directly into
each `.node` file before the service starts. This is done in an `ExecStartPre`
script that runs as root (the `+` prefix bypasses the service user):

```nix
ExecStartPre = let
  libPath = lib.makeLibraryPath (with pkgs; [ libusb1 udev stdenv.cc.cc.lib ]);
  script = pkgs.writeShellScript "companion-patch-native-addons" ''
    surfaces_dir="/var/lib/companion/.config/companion-nodejs/surfaces"
    if [ -d "$surfaces_dir" ]; then
      find "$surfaces_dir" -name "*.node" | while IFS= read -r f; do
        ${pkgs.patchelf}/bin/patchelf --set-rpath '$ORIGIN:${libPath}' "$f" 2>/dev/null || true
      done
    fi
  '';
in "+${script}";
```

---

## Fix 2 — `$ORIGIN` must be preserved in the RPATH

### Symptom

After Fix 1 some modules (specifically `mirabox-stream-dock`) still crash with:

```
libturbojpeg.so.0: cannot open shared object file: No such file or directory
```

### Root cause

`mirabox-stream-dock` bundles `libturbojpeg.so.0` **inside its own prebuild
directory** alongside the `.node` file:

```
prebuilds/jpeg-turbo-linux-arm64/
├── libturbojpeg.so.0
└── node-napi-v10.node
```

The original `.node` file's RPATH contains `$ORIGIN`, which tells the dynamic
linker to search the same directory as the `.node` file itself. A bare call to
`patchelf --set-rpath <nix-paths>` **replaces** the existing RPATH entirely,
removing `$ORIGIN` and breaking the bundled library lookup.

### Fix

Prepend `$ORIGIN` to the RPATH so it is preserved. The shell single-quotes
around `$ORIGIN` prevent the shell from expanding it; Nix still interpolates
`${libPath}` at build time:

```bash
patchelf --set-rpath '$ORIGIN:${libPath}' "$f"
#                     ^^^^^^^ shell single-quotes → literal $ORIGIN in ELF
#                                    ^^^^^^^^^ Nix interpolation at eval time
```

---

## Fix 3 — `StateDirectory=` mounts the data directory `noexec`

### Symptom

Even after Fixes 1 and 2 the mirabox module still crashes immediately with:

```
Error: …/node-napi-v10.node: failed to map segment from shared object
```

The `failed to map segment` error means `mmap(PROT_EXEC)` was refused —
the file was found, but the kernel prevented it from being mapped as
executable code.

### Root cause

**systemd 256+ applies `MS_NOEXEC` to all `StateDirectory=` bind mounts**
(not just `DynamicUser=` services). The bind mount that systemd creates for
`/var/lib/companion` is always mounted `nosuid,nodev,noexec`. Any `.node` file
that companion downloads and stores in its state directory cannot be `dlopen`-ed
by a child process.

This can be confirmed inside the service's mount namespace:

```bash
sudo nsenter -t <companion-pid> -m -- cat /proc/mounts | grep companion
# /dev/sda2 /var/lib/companion ext4 rw,nosuid,nodev,noexec,relatime,idmapped 0 0
#                                                           ^^^^^^
```

### Fix

Replace `StateDirectory=` with a `systemd.tmpfiles.rules` entry. Tmpfiles
creates the directory on the real filesystem without any bind mount, so the
kernel's exec permission comes from the underlying filesystem (typically `ext4`
without `noexec`):

```nix
# In the NixOS module — do NOT use StateDirectory for companion
systemd.tmpfiles.rules = [
  "d /var/lib/companion 0750 bitfocus-companion bitfocus-companion -"
];

systemd.services.bitfocus-companion = {
  serviceConfig = {
    User  = "bitfocus-companion";
    Group = "bitfocus-companion";
    WorkingDirectory = "/var/lib/companion";
    # StateDirectory = "companion";  ← REMOVED — would re-add noexec
  };
};
```

---

## Additional: DynamicUser is incompatible

Using `DynamicUser = true` compounds Fix 3: the state directory is placed under
`/var/lib/private/companion/` with an idmapped `noexec` bind mount, and the
unpredictable UID makes file ownership management harder. Use a static system
user instead:

```nix
users.users.bitfocus-companion = {
  isSystemUser = true;
  group = "bitfocus-companion";
  home  = "/var/lib/companion";
  createHome = false;
};
users.groups.bitfocus-companion = {};
```

---

## Summary table

| # | Error message | Root cause | Fix |
|---|--------------|-----------|-----|
| 1 | `libusb.so: cannot open shared object` | `LD_LIBRARY_PATH` not passed to child | `patchelf --set-rpath <nix-store-libs>` in `ExecStartPre` |
| 2 | `libturbojpeg.so.0: cannot open shared object` | `patchelf` overwrote `$ORIGIN` in RPATH | Prepend `$ORIGIN:` to the new RPATH |
| 3 | `failed to map segment from shared object` | `StateDirectory=` mounts path `noexec` (systemd 256+) | Use `systemd.tmpfiles.rules` instead of `StateDirectory=` |

---

## Affected modules

| Module | Native addons | Affected by fix |
|--------|--------------|-----------------|
| `mirabox-stream-dock` | `jpeg-turbo` (ARM64 prebuild) | 1, 2, 3 |
| `elgato-stream-deck` | none (pure JS) | — |
| `xkeys` | none (pure JS) | — |

Any future surface module that ships ARM or x86 prebuilt `.node` files will
require fixes 1 and 3. Fix 2 is only needed when the module bundles shared
libraries alongside the `.node` file.
