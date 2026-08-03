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

    hostKeyPath = mkOption {
      type = types.str;
      default = "/run/seter-identity/ssh_host_ed25519_key";
      description = "Root-only host-supplied Workspace SSH Identity private-key path.";
    };

    identityTransport = mkOption {
      type = types.enum [
        "virtiofs"
        "fw_cfg"
      ];
      default = "virtiofs";
      description = ''
        Trusted transport used to deliver the host-created Workspace SSH
        Identity. fw_cfg is used by the nested ARM QEMU Runner to avoid its
        slow virtiofs and shared-memory path.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.git ];

    services.openssh = mkIf ssh.enable {
      enable = true;
      hostKeys = [
        {
          type = "ed25519";
          path = ssh.hostKeyPath;
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

    systemd.services.seter-ssh-identity = mkIf (ssh.enable && ssh.identityTransport == "fw_cfg") {
      description = "Stage the fw_cfg Workspace SSH Identity";
      before = [ "sshd.service" ];
      requiredBy = [ "sshd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ImportCredential = [ "seter.ssh-host-key" ];
      };
      path = [ pkgs.coreutils ];
      script = ''
        install -d -m 0700 /run/seter-identity
        install -m 0600 \
          "$CREDENTIALS_DIRECTORY/seter.ssh-host-key" \
          ${lib.escapeShellArg ssh.hostKeyPath}
      '';
    };
  };
}
