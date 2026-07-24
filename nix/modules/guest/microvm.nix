{
  config,
  lib,
  ...
}:
let
  cfg = config.seter.guest;
  inherit (lib) mkIf mkOption types;
in
{
  options.seter.guest = {
    hypervisor = mkOption {
      type = types.enum [
        "cloud-hypervisor"
        "qemu"
      ];
      default = "cloud-hypervisor";
      description = "Hypervisor used by the declared microVM runner.";
    };

    memory = mkOption {
      type = types.ints.positive;
      default = 2048;
      description = "Guest memory in MiB.";
    };

    vcpu = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Number of virtual CPUs assigned to the guest.";
    };
  };

  config = mkIf cfg.enable {
    microvm = {
      hypervisor = cfg.hypervisor;
      mem = cfg.memory;
      vcpu = cfg.vcpu;
    };
  };
}
