{ ... }:
let
  # After creating the instance, use: limactl shell seter -- id -un
  operatorName = "operator";
  operatorKey = builtins.readFile ./operator-key.pub;
in
{
  networking.hostName = "seter-host";
  system.stateVersion = "25.11";

  users.users.${operatorName} = {
    isNormalUser = true;
    extraGroups = [
      "seter-operators"
      "wheel"
    ];
    openssh.authorizedKeys.keys = [ operatorKey ];
  };

  seter.host = {
    # policy.toml remains consumer-owned in the Client Exchange Directory.
    policyFile = ./policy.toml;
    # After the first Host deployment, export and review the generated public
    # certificate, then uncomment this before starting a Workspace.
    # proxyCaCertificate = builtins.readFile ./proxy-ca-cert.pem;

    workspaces.example = {
      repository.url = "https://github.com/owner/project.git";
      network = {
        address = "10.100.0.10";
        mac = "02:00:00:00:00:10";
        tap = "seter-example";
      };
      resources = {
        memoryMiB = 4096;
        vcpu = 4;
        cpuQuotaPercent = 400;
      };
      ssh.authorizedKeys = [ operatorKey ];
    };
  };
}
