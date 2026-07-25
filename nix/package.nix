{
  lib,
  rustPlatform,
  installShellFiles,
  makeWrapper,
  coreutils,
  e2fsprogs,
  nix,
  openssl,
  openssh,
  systemd,
}:
rustPlatform.buildRustPackage {
  pname = "seter";
  version = "0.1.0";
  src = lib.cleanSource ../.;
  cargoLock.lockFile = ../Cargo.lock;

  meta.mainProgram = "seter";

  nativeBuildInputs = [
    installShellFiles
    makeWrapper
  ];

  postInstall = ''
    installShellCompletion --cmd seter \
      --bash <($out/bin/seter completions bash) \
      --fish <($out/bin/seter completions fish) \
      --zsh <($out/bin/seter completions zsh)
  '';

  postFixup = ''
    wrapProgram $out/bin/seter \
      --set SETER_PRIVILEGED_HELPER "$out/bin/seter" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          e2fsprogs
          nix
          openssl
          openssh
          systemd
        ]
      }
  '';
}
