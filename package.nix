# Adapted from upstream: https://github.com/Tiebe/nixpkgs/blob/cd08eb2bba056f9bf8f047423919d763a91f87cc/pkgs/by-name/bi/bitfocus-companion/package.nix
# from https://github.com/NixOS/nixpkgs/pull/418848
{
  stdenv,
  lib,
  fetchFromGitHub,
  nodejs,
  git,
  python3,
  udev,
  yarn-berry_4,
  libusb1,
  iputils,
  procps,
  nettools,
  patchelf,
  makeWrapper,
  nix-update-script,
}: let
  yarn-berry = yarn-berry_4;

  selectSystem = attrs:
    attrs.${stdenv.hostPlatform.system} or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
  platform = selectSystem {
    x86_64-linux = "linux-x64";
    aarch64-linux = "linux-arm64";
    armv7l-linux = "linux-armv7l";
  };
in
  stdenv.mkDerivation rec {
    pname = "bitfocus-companion";
    version = "4.3.2";

    strictDeps = true;

    src = fetchFromGitHub {
      owner = "bitfocus";
      repo = "companion";
      tag = "v${version}";
      hash = "sha256-tiX478MMXBRujL1xqWrNtE5hElPr4Kr5FrOOYyM7fFo=";
    };

    passthru.updateScript = nix-update-script {};

    postPatch = ''
      # patch out git calls to generate version strings.
      # Cast to 'unknown as T' so TypeScript 6 accepts the string literal return in the generic goSilent<T> function
      substituteInPlace tools/lib.mts --replace-fail "return await fcn()" "return \"v${version}\" as unknown as T"

      # remove the yarn install during the build, since there is no internet connection, and everything has already been installed by yarnBerryConfigHook
      substituteInPlace tools/build/dist.mts \
        --replace-fail 'await $`yarn --cwd node_modules/better-sqlite3 prebuild-install --arch=''${platformInfo.nodeArch} --platform=''${platformInfo.nodePlatform}`' "" \
        --replace-fail 'await $`yarn workspace @companion-app/launcher-ui build`' "" \
        --replace-fail 'await $`yarn --cwd node_modules/better-sqlite3 prebuild-install`' ""

      substituteInPlace tools/build/package.mts --replace-fail "await $\`yarn install --no-immutable\`" ""

      # remove node download, since we'll use the nix version
      # Use explicit type annotation to avoid 'noImplicitAny' strict error from the empty array literal
      substituteInPlace tools/build/package.mts \
        --replace-fail "const nodeVersions = await fetchNodejs(platformInfo)" "const nodeVersions: [string, string][] = []" \
        --replace-fail "await fs.createSymlink(latestRuntimeDir, path.join(runtimesDir, 'main'), 'dir')" "" \
        --replace-fail "const builtinSurfaceCacheDir = await fetchBuiltinSurfaceModules()" "const builtinSurfaceCacheDir = await (async () => { try { return await fetchBuiltinSurfaceModules() } catch { return null } })()" \
        --replace-fail "await fs.copy(builtinSurfaceCacheDir, builtinSurfacesDir)" "if (builtinSurfaceCacheDir) await fs.copy(builtinSurfaceCacheDir, builtinSurfacesDir)"

      # Disable strict mode in the tools TypeScript project to allow the Nix build to succeed
      substituteInPlace tsconfig.tools.json \
        --replace-fail '"strict": true' '"strict": false'

      # The @ts-expect-error for the webpack config import is now unused (webpack config has types).
      # Change to @ts-ignore which silently suppresses even when no error exists.
      substituteInPlace tools/build/dist.mts \
        --replace-fail '// @ts-expect-error Untyped webpack config' '// @ts-ignore Untyped webpack config'

      substituteInPlace companion/lib/Instance/NodePath.ts \
        --replace-fail "if (!(await fs.pathExists(nodePath))) return null" "return '${lib.getExe nodejs}'" \
    '';

    preBuild = ''
      # Fix the ELF interpreter of the bundled dart binary so it can run in the Nix sandbox.
      # sass-embedded ships an architecture-specific binary under node_modules.
      dart_bin=""
      for p in \
        node_modules/sass-embedded-linux-arm64/dart-sass/src/dart \
        node_modules/sass-embedded-linux-x64/dart-sass/src/dart \
        node_modules/sass-embedded-linux-ia32/dart-sass/src/dart
      do
        if [[ -f "$p" ]]; then
          dart_bin="$p"
          break
        fi
      done

      if [[ -n "$dart_bin" ]]; then
        patchelf --set-interpreter "${stdenv.cc.bintools.dynamicLinker}" "$dart_bin"
      else
        echo "warning: sass-embedded dart binary not found; skipping patchelf"
      fi
    '';

    nativeBuildInputs = [
      nodejs
      yarn-berry.yarnBerryConfigHook
      git
      python3
      yarn-berry
      makeWrapper
      patchelf
    ];

    buildInputs = [
      libusb1
      nodejs
      udev
    ];

    missingHashes = ./missing-hashes.json;

    offlineCache = yarn-berry.fetchYarnBerryDeps {
      inherit src missingHashes;
      hash = "sha256-msXcGxkfqLhLgCLiVgOGlhxTXIXWVFJWIRw15I3W/s8=";
    };

    env = {
      ELECTRON_SKIP_BINARY_DOWNLOAD = 1;
      SKIP_LAUNCH_CHECK = true;
      ELECTRON = 0;
    };

    # with dontConfigure it doesn't seem to retrieve node_modules, so empty configurePhase instead
    configurePhase = ''
      runHook preConfigure
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild

      yarn dist ${platform}

      runHook postBuild
    '';

    preInstall = ''
      # remove node runtime, since we will always use the nix node runtime
      rm -rf .cache/node-runtimes
      rm -rf dist/node-runtimes
      rm -rf node_modules/app-builder-bin
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/bitfocus-companion
      cp -r * $out/share/bitfocus-companion/

      # Upstream docker includes udev at both build and runtime
      # Upstream docker includes iputils at runtime
      makeWrapper ${lib.getExe nodejs} $out/bin/bitfocus-companion \
        --add-flags $out/share/bitfocus-companion/dist/main.js \
        --set LD_LIBRARY_PATH "${lib.makeLibraryPath [libusb1 udev]}" \
        --set NODE_PATH $out/share/bitfocus-companion/node_modules \
        --suffix PATH : "${lib.makeBinPath [iputils procps nettools]}"

      runHook postInstall
    '';

    meta = {
      description = "Program for controlling Stream Deck devices";
      longDescription = "Bitfocus Companion enables the Elgato Stream Deck and other controllers to be a professional shotbox surface for an increasing amount of different presentation switchers, video playback software and broadcast equipment.";
      homepage = "https://bitfocus.io/companion";
      license = lib.licenses.mit;
      maintainers = with lib.maintainers; [tiebe];
      mainProgram = "bitfocus-companion";
      platforms = lib.platforms.linux;
    };
  }
