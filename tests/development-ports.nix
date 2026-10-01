{ pkgs, identityGuestConfiguration }:
let
  lib = pkgs.lib;
in
pkgs.testers.runNixOSTest {
  name = "seter-development-ports";
  nodes.client = { };
  nodes.workspace = {
    networking.firewall.allowedTCPPorts =
      identityGuestConfiguration.config.networking.firewall.allowedTCPPorts;
    systemd.services = lib.genAttrs [ "allowed" "blocked" ] (name: {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${pkgs.python3}/bin/python -m http.server ${
          if name == "allowed" then "3000" else "3001"
        } --bind 0.0.0.0";
        WorkingDirectory = "/tmp";
      };
    });
  };
  testScript = ''
    start_all()
    workspace.wait_for_open_port(3000)
    workspace.wait_for_open_port(3001)
    workspace.succeed("curl --fail http://127.0.0.1:3001/")
    client.succeed("curl --fail --max-time 5 http://workspace:3000/")
    client.fail("curl --fail --max-time 3 http://workspace:3001/")
  '';
}
