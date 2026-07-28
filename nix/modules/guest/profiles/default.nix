{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.hostName = "seter-${config.seter.guest.name}";

  seter.guest.ssh.authorizedKeys = lib.mkDefault [ ];

  # programs.direnv installs the bash hook itself via enableBashIntegration;
  # adding one here would run the hook twice per prompt.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # A default-deny workspace should not generate repeated traffic for a
  # service whose upstreams have not been granted explicitly.
  services.timesyncd.enable = false;

  environment.systemPackages = with pkgs; [
    bashInteractive
    coreutils
    direnv
    git
    nix-direnv
    openssh
    util-linux
  ];

  system.stateVersion = "24.11";
}
