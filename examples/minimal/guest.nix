{
  config,
  lib,
  ...
}:
{
  networking.hostName = "seter-minimal";
  microvm.vsock.cid = 10;

  # Network and storage identity comes from the generated workspace module in
  # parts/examples.nix. Project-owned guest configuration contains only the
  # workload-specific settings.
  seter.guest.projectVolume.size = 512;

  # A real workspace supplies its developer's public key here. Keeping the
  # repository example keyless avoids embedding personal access material.
  seter.guest.ssh.authorizedKeys = [ ];

  system.stateVersion = lib.trivial.release;
}
