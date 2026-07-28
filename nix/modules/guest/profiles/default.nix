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
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };

  # Ordinary development flakes are the workload interface of the default
  # profile. Keep the required modern Nix commands enabled in the trusted
  # Runner rather than asking each repository to carry guest configuration.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Git, Nix, and other OpenSSL consumers use the generated system bundle.
  # The host's public interception CA, when configured, is merged into this
  # same bundle by the low-level guest module.
  security.pki.installCACerts = true;

  # A default-deny workspace should not generate repeated traffic for a
  # service whose upstreams have not been granted explicitly.
  services.timesyncd.enable = false;

  environment.systemPackages = with pkgs; [
    bashInteractive
    coreutils
    curl
    diffutils
    direnv
    file
    findutils
    gawk
    git
    gnugrep
    gnused
    gzip
    less
    nix-direnv
    openssh
    procps
    gnutar
    util-linux
    which
    xz
  ];

  system.stateVersion = "24.11";
}
