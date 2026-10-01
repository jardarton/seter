{
  lib,
  pkgs,
  fixtures,
}:
let
  inherit (fixtures) qemuIdentityGuestConfiguration;
  qemuHostConfiguration = fixtures.mkHostWith {
    runner.hypervisor = "qemu";
    workspaces = lib.mapAttrs (
      _: workspace:
      workspace
      // {
        resources = workspace.resources // {
          vcpu = 4;
        };
      }
    ) fixtures.validWorkspaces;
  };
  qemuRunner = qemuIdentityGuestConfiguration.config.microvm.declaredRunner;
in
assert
  qemuIdentityGuestConfiguration.config.boot.kernelPackages.kernel.version
  == pkgs.linuxPackages_6_12.kernel.version;
assert !qemuIdentityGuestConfiguration.config.console.enable;
assert
  qemuIdentityGuestConfiguration.config.microvm.qemu.machineOpts == {
    accel = "kvm";
    gic-version = "max";
  };
assert qemuHostConfiguration.config.boot.kernelPackages.kernel == pkgs.linuxPackages_6_12.kernel;
pkgs.runCommand "seter-arm-qemu-runner-check"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
  }
  ''
    runner=${qemuRunner}/bin/microvm-run
    grep -F -- "qemu-system-aarch64" "$runner"
    grep -F -- "-M 'virt,accel=kvm,gic-version=max'" "$runner"
    grep -F -- "-smp 4" "$runner"
    grep -F -- "linux-6.12" "$runner"
    grep -F -- "-fw_cfg 'name=opt/io.systemd.credentials/seter.ssh-host-key,file=/run/credentials/seter-vm-identity.service/ssh_host_ed25519_key'" "$runner"
    ! grep -F -- "vhost-user-fs" "$runner"
    ! grep -F -- "memory-backend-memfd" "$runner"
    touch "$out"
  ''
