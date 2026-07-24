{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.seter.guest;
  ssh = cfg.ssh;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
in
{
  options.seter.guest.ssh = {
    enable = mkEnableOption "SSH access to the project guest" // {
      default = true;
    };

    user = mkOption {
      type = types.str;
      default = "seter";
      description = "Unprivileged guest user used for Seter commands.";
    };

    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "SSH public keys authorized for the Seter guest user.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.git ];

    services.openssh = mkIf ssh.enable {
      enable = true;
      # The guest root is ephemeral, so retain its server identity on the
      # persistent project volume without exposing it to the project user.
      hostKeys = [
        {
          type = "ed25519";
          path = "${cfg.projectDirectory}/.seter-state/ssh/ssh_host_ed25519_key";
        }
      ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    users.users.${ssh.user} = mkIf ssh.enable {
      isNormalUser = true;
      createHome = true;
      home = "/home/${ssh.user}";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = ssh.authorizedKeys;
    };
  };
}
