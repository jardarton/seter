{
  inputs,
  self,
  system,
  proxyTrustCa,
}:
let
  # Public, self-signed test CA. The matching private key is
  # deliberately not retained in the repository.
  proxyCaCertificate = builtins.readFile proxyTrustCa;
  guestConfiguration = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.guest
      {
        seter.guest = {
          enable = true;
          network.enable = true;
          proxyCaCertificate = proxyCaCertificate;
          secretPlaceholders = {
            GITHUB_TOKEN = "seter-placeholder-github-0123456789abcdef";
            GH_TOKEN = "seter-placeholder-github-0123456789abcdef";
          };
        };
        system.stateVersion = "24.11";
      }
    ];
  };
  sessionVariables = guestConfiguration.config.environment.sessionVariables;
in
assert sessionVariables.HTTP_PROXY == "http://10.100.0.1:18081";
assert sessionVariables.HTTPS_PROXY == "http://10.100.0.1:18081";
assert sessionVariables.NO_PROXY == "127.0.0.1,localhost,::1,10.100.0.10";
assert sessionVariables.GITHUB_TOKEN == "seter-placeholder-github-0123456789abcdef";
assert sessionVariables.GH_TOKEN == sessionVariables.GITHUB_TOKEN;
assert builtins.elem proxyCaCertificate guestConfiguration.config.security.pki.certificates;
guestConfiguration.config.system.build.toplevel
