{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.guest;
  volume = cfg.projectVolume;
  nixStore = cfg.nixStore;
  nixGcGuard =
    pkgs.runCommand "seter-nix-gc-guard"
      {
        meta.priority = -10;
      }
      ''
        mkdir -p "$out/bin"

        cat > "$out/bin/nix-collect-garbage" <<'EOF'
        #!${pkgs.runtimeShell}
        echo "Seter: guest Nix garbage collection is disabled because overlay deletion can hide shared lower-store paths; reset the private Nix image to reclaim it safely" >&2
        exit 1
        EOF

        cat > "$out/bin/nix" <<'EOF'
        #!${pkgs.runtimeShell}
        if { test "''${1-}" = store && test "''${2-}" = gc; } \
          || { test "''${1-}" = store && test "''${2-}" = delete; }; then
          echo "Seter: guest Nix store deletion is disabled because it can create persistent lower-store whiteouts; reset the private Nix image instead" >&2
          exit 1
        fi
        exec ${config.nix.package}/bin/nix "$@"
        EOF

        cat > "$out/bin/nix-store" <<'EOF'
        #!${pkgs.runtimeShell}
        for argument in "$@"; do
          if test "$argument" = --gc || test "$argument" = --delete; then
            echo "Seter: guest Nix store deletion is disabled because it can create persistent lower-store whiteouts; reset the private Nix image instead" >&2
            exit 1
          fi
        done
        exec ${config.nix.package}/bin/nix-store "$@"
        EOF

        chmod +x "$out/bin/"*
      '';
  inherit (lib)
    hasPrefix
    mkEnableOption
    mkIf
    mkOption
    optionals
    types
    ;
in
{
  options.seter.guest.projectVolume = {
    enable = mkEnableOption "a persistent project volume" // {
      default = true;
    };

    image = mkOption {
      type = types.str;
      default = "${cfg.name}-project.img";
      description = "Host path to the project volume image, absolute or relative to the runner directory.";
    };

    size = mkOption {
      type = types.ints.positive;
      default = 4096;
      description = "Project volume size in MiB.";
    };
  };

  options.seter.guest.nixStore = {
    enable = mkEnableOption "a persistent private writable Nix store overlay" // {
      default = true;
    };

    image = mkOption {
      type = types.str;
      default = "${cfg.name}-nix-store.img";
      description = ''
        Host path to the persistent Nix state volume, absolute or relative to
        the runner directory. The volume supplies the writable overlay above
        the host's read-only store and retains the guest Nix database.
      '';
    };

    size = mkOption {
      type = types.ints.positive;
      default = 16384;
      description = "Initial capacity of the workspace-private Nix store volume in MiB.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.projectDirectory != "/nix" && !hasPrefix "/nix/" cfg.projectDirectory;
        message = "seter.guest.projectDirectory must not be inside the persistent /nix volume";
      }
      {
        assertion = !nixStore.enable || !volume.enable || nixStore.image != volume.image;
        message = "seter.guest.nixStore.image must differ from seter.guest.projectVolume.image";
      }
    ];

    # microvm.nix supplies a tmpfs root by default. Do not define a persistent
    # root filesystem here. The project volume and private Nix state survive;
    # all other guest state remains ephemeral.
    microvm.volumes =
      optionals volume.enable [
        {
          inherit (volume) image size;
          label = "seter-project";
          mountPoint = cfg.projectDirectory;
          fsType = "ext4";
        }
      ]
      ++ optionals nixStore.enable [
        {
          inherit (nixStore) image size;
          label = "seter-nix";
          # Mount one persistent filesystem at /nix so both the overlay's
          # upper/work directories and /nix/var/nix use the same bounded
          # workspace-private volume. The host share remains a read-only
          # lower layer at /nix/.ro-store.
          mountPoint = "/nix";
          fsType = "ext4";
        }
      ];

    microvm.writableStoreOverlay = mkIf nixStore.enable "/nix/.rw-store";
    fileSystems = mkIf nixStore.enable {
      "/nix".neededForBoot = true;
    };

    # microvm.nix enables nix-daemon for a writable overlay. Keep builds
    # sandboxed inside the guest and disable store optimisation, which
    # upstream explicitly declares incompatible with overlay stores.
    nix.optimise.automatic = mkIf nixStore.enable false;
    nix.gc.automatic = mkIf nixStore.enable false;
    nix.settings = mkIf nixStore.enable {
      auto-optimise-store = false;
      gc-reserved-space = 0;
      max-free = 0;
      min-free = 0;
      sandbox = true;
    };

    # Nix GC sees the merged overlay namespace, including unrelated paths in
    # the shared host store. Deleting any lower-only path creates a persistent
    # whiteout in the private upper layer and can hide a future runner closure.
    # Disable daemon-triggered collection and shadow the normal destructive
    # CLI entry points to prevent accidents. This is not a guest security
    # boundary: a hostile workspace can call the real store binary directly,
    # but it can already corrupt its own private image and recovery is the same.
    environment.systemPackages = mkIf nixStore.enable [ nixGcGuard ];

    # The guest Nix database is persistent, so closures loaded from the
    # read-only host store remain registered across runner changes. Preserve
    # every booted system as a guest GC root so its registrations stay live.
    # The host keeps the corresponding runner generations rooted as the other
    # half of this persistent-database contract.
    boot.postBootCommands = mkIf nixStore.enable ''
      booted_system="$(${pkgs.coreutils}/bin/readlink -f /run/booted-system)"
      booted_root=/nix/var/nix/gcroots/seter-lower-closures/"$(${pkgs.coreutils}/bin/basename "$booted_system")"
      ${pkgs.coreutils}/bin/mkdir -p /nix/var/nix/gcroots/seter-lower-closures
      ${pkgs.coreutils}/bin/ln -sfn "$booted_system" "$booted_root"
    '';

    systemd.tmpfiles.settings."10-seter-project" = mkIf (volume.enable && cfg.ssh.enable) {
      ${cfg.projectDirectory}.d = {
        user = cfg.ssh.user;
        group = "users";
        mode = "0755";
      };
      "${cfg.projectDirectory}/.seter-state".d = {
        user = "root";
        group = "root";
        mode = "0700";
      };
    };

    microvm.shares = [
      {
        proto = "virtiofs";
        tag = "ro-store";
        # Keep the runner and host module on one deterministic socket
        # contract. The workspace name is validated by the host registry.
        socket = "/run/seter/${cfg.name}/virtiofs-ro-store.sock";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        readOnly = true;
      }
    ];
  };
}
