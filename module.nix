{
  config,
  lib,
  pkgs,
  ...
}: let
  options.programs.companion = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "Which companion package to install.";
    };
    enable = lib.mkEnableOption "Add Bitfocus Companion to installed packages.";
    runAsService = lib.mkEnableOption "Run Companion as a systemd service instead of just installing the package.";
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to start Bitfocus Companion automatically at boot (only used when runAsService is enabled).";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "bitfocus-companion";
      description = "User under which the Companion service will run. The user is created as a system user if it does not already exist.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "bitfocus-companion";
      description = "Group under which the Companion service will run. The group is created if it does not already exist.";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/companion";
      description = ''
        Absolute path to the directory where Companion stores its state and
        downloaded surface modules.  Must not be a path managed by
        <option>StateDirectory=</option> — systemd 256+ mounts those with
        <literal>MS_NOEXEC</literal>, which prevents dlopen of downloaded
        native <literal>.node</literal> addons.
      '';
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to open firewall ports for Companion.
        Only the web interface port (TCP 8000 by default) is opened.
        If you use OSC or other companion protocols add their ports separately.
      '';
    };
  };
  cfg = config.programs.companion;
in {
  inherit options;
  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.mkIf (!cfg.runAsService) [cfg.package];

    # Static system user so udev rules and group membership (e.g. plugdev for
    # USB HID access) can reference a stable, named identity.  DynamicUser= is
    # intentionally avoided: its ephemeral identity cannot appear in /etc/passwd,
    # cannot hold supplementary group memberships, and cannot be named in udev
    # OWNER=/GROUP= fields.
    users.users.${cfg.user} = lib.mkIf cfg.runAsService {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = false;
    };
    users.groups.${cfg.group} = lib.mkIf cfg.runAsService {};

    # Create the state directory via tmpfiles rather than StateDirectory=.
    # systemd 256+ mounts StateDirectory= paths with MS_NOEXEC (as an idmapped
    # bind mount), which prevents dlopen of native .node surface addons that
    # Companion downloads at runtime.
    systemd.tmpfiles.rules = lib.mkIf cfg.runAsService [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.companion = lib.mkIf cfg.runAsService {
      description = "Bitfocus Companion";
      wantedBy = lib.mkIf cfg.autoStart ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = let
        # Libraries needed by surface-module native addons (e.g. libusb for
        # Stream Deck, libudev for Mirabox docks).
        libPath = lib.makeLibraryPath (with pkgs; [libusb1 udev stdenv.cc.cc.lib]);
        # Companion's child-process spawner strips most env vars (including
        # LD_LIBRARY_PATH) before starting surface modules, so we bake the
        # library paths directly into the .node RPATH instead.  $ORIGIN prefix
        # preserves relative-path entries already in the binary (e.g.
        # libturbojpeg.so.0 bundled alongside the addon).
        patchScript = pkgs.writeShellScript "companion-patch-native-addons" ''
          state_dir="${cfg.stateDir}"

          # Fix ownership of files left by a previous DynamicUser= run.
          # DynamicUser= stores files owned by nobody:nogroup on the real fs.
          if [ -d "$state_dir" ]; then
            find "$state_dir" \( -user nobody -o -group nogroup \) \
              -exec chown ${cfg.user}:${cfg.group} {} + 2>/dev/null || true
          fi

          # Patch RPATH of downloaded surface-module native addons.
          surfaces_dir="$state_dir/.config/companion-nodejs/surfaces"
          if [ -d "$surfaces_dir" ]; then
            find "$surfaces_dir" -name "*.node" | while IFS= read -r f; do
              ${pkgs.patchelf}/bin/patchelf --set-rpath '$ORIGIN:${libPath}' "$f" 2>/dev/null || true
            done
          fi
        '';
      in {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        # Run as root so we can chown old DynamicUser files and patch RPATHs.
        ExecStartPre = "+${patchScript}";
        ExecStart = "${cfg.package}/bin/bitfocus-companion";
        Restart = "on-failure";
        RestartSec = "10s";
        # Companion locates its config via HOME, not CWD.  Use / to avoid CHDIR
        # failures if the state directory doesn't exist yet on first boot.
        WorkingDirectory = "/";
        Environment = "HOME=${cfg.stateDir}";
        NoNewPrivileges = true;
        ProtectSystem = "full";
        # Data lives in /var/lib, not ~; no reason to expose home directories.
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    networking.firewall = lib.mkIf (cfg.runAsService && cfg.openFirewall) {
      # TCP 8000: Companion web UI / REST API.
      # For OSC add the relevant UDP ports (companion defaults: 12321 in, 12322 out).
      allowedTCPPorts = [8000];
    };
  };
}
