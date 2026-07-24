{
  config,
  lib,
  ...
}:
let
  cfg = config.seter.guest;
  volume = cfg.projectVolume;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
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

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.projectDirectory != "/nix/store";
        message = "seter.guest.projectDirectory must not replace /nix/store";
      }
    ];

    # microvm.nix supplies a tmpfs root by default. Do not define a persistent
    # root filesystem here: only the project volume survives a reboot.
    microvm.volumes = mkIf volume.enable [
      {
        inherit (volume) image size;
        label = "seter-project";
        mountPoint = cfg.projectDirectory;
        fsType = "ext4";
      }
    ];

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
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        readOnly = true;
      }
    ];
  };
}
