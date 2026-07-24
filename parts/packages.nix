{ ... }: {
  perSystem =
    { pkgs, ... }:
    let
      seter = pkgs.rustPlatform.buildRustPackage {
        pname = "seter";
        version = "0.1.0";
        src = pkgs.lib.cleanSource ../.;
        cargoLock.lockFile = ../Cargo.lock;

        meta.mainProgram = "seter";

        nativeBuildInputs = [ pkgs.installShellFiles ];

        postInstall = ''
          installShellCompletion --cmd seter \
            --bash <($out/bin/seter completions bash) \
            --fish <($out/bin/seter completions fish) \
            --zsh <($out/bin/seter completions zsh)
        '';
      };
    in
    {
      packages = {
        inherit seter;
        default = seter;
      };

      apps.default = {
        type = "app";
        program = pkgs.lib.getExe seter;
        meta.description = "Manage isolated, Nix-managed project VMs";
      };
    };
}
