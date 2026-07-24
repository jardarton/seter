{
  config,
  lib,
  ...
}:
{
  networking.hostName = "seter-minimal";
  microvm.vsock.cid = 10;

  seter.guest = {
    enable = true;
    name = "minimal";

    projectVolume = {
      image = "minimal-project.img";
      size = 512;
    };

    network = {
      enable = true;
      tap = "seter-minimal";
      mac = "02:00:00:00:00:10";
      address = "10.100.0.10";
      gateway = "10.100.0.1";
    };
  };

  # A real workspace supplies its developer's public key here. Keeping the
  # repository example keyless avoids embedding personal access material.
  seter.guest.ssh.authorizedKeys = [ ];

  system.stateVersion = lib.trivial.release;
}
