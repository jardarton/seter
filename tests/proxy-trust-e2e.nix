{
  self,
  lib,
  pkgs,
  proxyTrustCa,
}:
let
  proxyTrustServerCertificate = ./fixtures/proxy-e2e-server-cert.pem;
  proxyTrustServerKey = ./fixtures/proxy-e2e-server-key.pem;

  explicitProxyRelay = ./helpers/explicit-proxy-relay.py;

in
pkgs.testers.runNixOSTest {
  name = "seter-proxy-trust-e2e";

  nodes = {
    guest =
      { lib, ... }:
      {
        imports = [ self.nixosModules.guest ];
        # The microvm module's package overlay is needed for runners,
        # but this check boots the guest configuration directly as a
        # NixOS test node whose package set is intentionally read-only.
        nixpkgs.overlays = lib.mkForce [ ];

        environment.systemPackages = [ pkgs.curl ];
        users.users.tester.isNormalUser = true;

        seter.guest = {
          enable = true;
          network.enable = false;
          projectVolume.enable = false;
          ssh.enable = false;
          proxy = "http://proxy:18081";
          proxyCaCertificate = builtins.readFile proxyTrustCa;
          secretPlaceholders.GITHUB_TOKEN = "seter-placeholder-github-0123456789abcdef";
        };

        virtualisation.memorySize = 1024;
        system.stateVersion = "24.11";
      };

    proxy = {
      environment.systemPackages = [ pkgs.python3 ];
      networking.firewall.allowedTCPPorts = [ 18081 ];
      virtualisation.memorySize = 768;
      system.stateVersion = "24.11";
    };
  };

  testScript = ''
    start_all()

    proxy.succeed("mkdir -p /tmp/seter-proxy-trust-upstream; printf 'trusted proxy e2e\\n' > /tmp/seter-proxy-trust-upstream/index.html")
    proxy.succeed("systemd-run --unit=seter-proxy-trust-upstream --property=Type=simple -- ${pkgs.runtimeShell} -c 'cd /tmp/seter-proxy-trust-upstream && exec ${lib.getExe pkgs.openssl} s_server -quiet -accept 127.0.0.1:8443 -cert ${proxyTrustServerCertificate} -key ${proxyTrustServerKey} -WWW'")
    proxy.wait_for_unit("seter-proxy-trust-upstream.service")
    proxy.succeed("systemd-run --unit=seter-proxy-trust-relay --property=Type=simple -- ${pkgs.python3}/bin/python ${explicitProxyRelay}")
    proxy.wait_for_unit("seter-proxy-trust-relay.service")

    guest.wait_until_succeeds("getent ahostsv4 proxy")
    guest.succeed("su - tester -c 'test \"$HTTPS_PROXY\" = http://proxy:18081; test \"$NO_PROXY\" = 127.0.0.1,localhost,::1'")
    guest.succeed("su - tester -c 'test \"$GITHUB_TOKEN\" = seter-placeholder-github-0123456789abcdef'")
    guest.wait_until_succeeds("su - tester -c 'curl --fail --silent https://proxy-e2e.example/index.html | grep -F \"trusted proxy e2e\"'")
  '';
}
