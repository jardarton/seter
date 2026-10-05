{ pkgs, seter }:
pkgs.testers.runNixOSTest {
  name = "seter-native-client";
  nodes.machine = {
    services.openssh.enable = true;
    environment.systemPackages = [
      seter
      pkgs.openssh
      pkgs.python3
    ];
    users.users.operator = {
      isNormalUser = true;
      password = "synthetic-test-password";
    };
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("su - operator -c '${pkgs.python3}/bin/python ${./macos-client.py} ${pkgs.lib.getExe seter}'")
  '';
}
