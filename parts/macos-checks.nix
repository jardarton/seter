{ inputs, self, ... }:
let
  limaHost = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.limaHost
      { system.stateVersion = "25.11"; }
    ];
  };
in
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      # Inspect the generated script natively; building the ARM script here
      # would require an aarch64 builder even though this is a static check.
      nativeLimaHost = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.limaHost
          { system.stateVersion = "25.11"; }
        ];
      };
      exchangeScript = nativeLimaHost.config.systemd.services.seter-lima-exchange.serviceConfig.ExecStart;
      bootstrapScript =
        nativeLimaHost.config.systemd.services.seter-lima-bootstrap-key.serviceConfig.ExecStart;
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.macos-exchange-activation = pkgs.testers.runNixOSTest {
        name = "seter-exchange-activation";
        nodes.machine = {
          system.switch.enable = true;
          system.activationScripts.seterLimaExchange =
            nativeLimaHost.config.system.activationScripts.seterLimaExchange;
          systemd.services.seter-lima-exchange = {
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            # Synthetic mount state: helper parsing and mount validation are
            # exercised separately by lima-host-scripts.py.
            script = "touch /run/synthetic-exchange-mounted";
          };
        };
        testScript = ''
          machine.start()
          machine.wait_for_unit("seter-lima-exchange.service")
          for _ in range(2):
              machine.succeed("rm /run/synthetic-exchange-mounted")
              machine.succeed("systemctl is-active seter-lima-exchange.service")
              machine.succeed("/run/current-system/bin/switch-to-configuration test")
              machine.succeed("test -f /run/synthetic-exchange-mounted")
        '';
      };

      checks.macos-lima-host = pkgs.runCommand "seter-macos-lima-host-check" { } ''
        test ${lib.escapeShellArg limaHost.config.seter.host.runner.hypervisor} = qemu
        test ${lib.escapeShellArg limaHost.config.fileSystems."/".device} = /dev/disk/by-label/nixos
        test ${lib.escapeShellArg limaHost.config.fileSystems."/boot".device} = /dev/vda1
        test ${lib.escapeShellArg (toString limaHost.config.services.lima.enable)} = 1
        test ${lib.escapeShellArg (toString limaHost.config.services.openssh.enable)} = 1
        test ${lib.escapeShellArg (toString limaHost.config.services.openssh.authorizedKeysInHomedir)} = ""
        test ${lib.escapeShellArg (builtins.elem "/run/seter-lima-ssh/%u" limaHost.config.services.openssh.authorizedKeysFiles)} = 1
        test ${lib.escapeShellArg limaHost.config.boot.kernelPackages.kernel.version} = ${lib.escapeShellArg pkgs.linuxPackages_6_12.kernel.version}
        test ${lib.escapeShellArg (builtins.unsafeDiscardStringContext limaHost.config.system.activationScripts.seterLimaAuthorizedKeysDirectory.text)} != ""
        test ${lib.escapeShellArg limaHost.config.systemd.services.seter-lima-bootstrap-key.serviceConfig.Type} = oneshot
        test ${lib.escapeShellArg limaHost.config.systemd.services.seter-lima-exchange.serviceConfig.Type} = oneshot
        test ${lib.escapeShellArg (lib.hasInfix "echo seter-lima-exchange.service >> /run/nixos/activation-restart-list" limaHost.config.system.activationScripts.seterLimaExchange.text)} = 1
        test ${lib.escapeShellArg (builtins.elem "multi-user.target" limaHost.config.systemd.services.seter-lima-exchange.wantedBy)} = 1
        grep -F '/workspace/seter-exchange' ${exchangeScript}
        grep -F 'mount -t virtiofs -o rw' ${exchangeScript}
        ${pkgs.bash}/bin/bash -n ${exchangeScript}
        ${pkgs.bash}/bin/bash -n ${bootstrapScript}
        ${pkgs.python3}/bin/python ${../tests/lima-host-scripts.py} ${bootstrapScript} ${exchangeScript}

        grep -F 'nixos-lima-v0.2.1-aarch64.qcow2' ${../lima/seter.yaml}
        grep -F 'sha512:748c723b69dbdec40a9acaf78cc9070ae784dcb64b0856ab906efdac822d9abcc65565b8f8dfa4cf8b49cc6c12c372072e83bb5ed9247330a7c22675d9e141ce' ${../lima/seter.yaml}
        grep -F 'nestedVirtualization: true' ${../lima/seter.yaml}
        grep -F 'mountPoint: "/workspace/seter-exchange"' ${../lima/seter.yaml}
        grep -F 'memory: "16GiB"' ${../lima/seter.yaml}
        grep -F 'disk: "120GiB"' ${../lima/seter.yaml}
        grep -F 'SETER_LIMA_MEMORY:-16}' ${../scripts/macos-host}
        grep -F 'SETER_LIMA_DISK:-120}' ${../scripts/macos-host}

        ${pkgs.bash}/bin/bash -n ${../scripts/macos-host}
        touch "$out"
      '';
    };
}
