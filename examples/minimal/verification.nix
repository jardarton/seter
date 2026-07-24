{
  config,
  lib,
  pkgs,
  ...
}:
{
  # The automated boot check does not need a host tap interface. It verifies
  # the guest through a report written to the persistent project volume.
  seter.guest.network.enable = lib.mkForce false;
  seter.guest.projectVolume.image = lib.mkForce "test-project.img";

  # The standalone verification runs without the Seter host module and must
  # keep its VirtioFS socket in the temporary runner working directory.
  microvm.shares = lib.mkForce [
    {
      proto = "virtiofs";
      tag = "ro-store";
      socket = "seter-minimal-virtiofs-ro-store.sock";
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      readOnly = true;
    }
  ];

  systemd.services.seter-vertical-slice-check = {
    description = "Verify the Seter minimal guest";
    wantedBy = [ "multi-user.target" ];
    after = [
      "local-fs.target"
      "sshd.service"
    ];
    requires = [ "sshd.service" ];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.systemd
    ];
    script = ''
      set -eu
      report=/project/seter-verification

      test -e /etc/vm-guest
      test "$(findmnt -n -o FSTYPE /)" = tmpfs
      runuser -u ${lib.escapeShellArg config.seter.guest.ssh.user} -- touch /project/writable
      host_key=${lib.escapeShellArg (builtins.head config.services.openssh.hostKeys).path}
      test -s "$host_key"
      test "$(stat -c %a "$host_key")" = 600
      test "$(stat -c %U:%G "$host_key")" = root:root
      runuser -u ${lib.escapeShellArg config.seter.guest.ssh.user} -- test ! -r "$host_key"
      test "$(stat -c %a "$(dirname "$(dirname "$host_key")")")" = 700
      if touch /nix/store/seter-must-remain-read-only 2>/dev/null; then
        echo "/nix/store was writable" >&2
        exit 1
      fi
      systemctl is-active --quiet sshd.service

      printf '%s\n' marker root-tmpfs project-writable store-read-only ssh-active ssh-host-key-persistent > "$report"
      sync
      systemctl poweroff
    '';
  };
}
