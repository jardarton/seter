{
  lib,
  rustPlatform,
  installShellFiles,
  makeWrapper,
  coreutils,
  openssl,
  openssh,
  stdenv,
  systemd,
  lima,
  nixos-rebuild-ng,
}:
rustPlatform.buildRustPackage {
  pname = "seter";
  version = "0.1.0";
  # Only the crate sources. A repo-wide source would make every documentation
  # or Nix module edit rebuild the binary, and with it every check that embeds
  # this package in a VM image.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../crates
    ];
  };
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
      ${lib.optionalString stdenv.isLinux ''--set SETER_PRIVILEGED_HELPER "$out/bin/seter"''} \
      --prefix PATH : ${
        lib.makeBinPath (
          [
            coreutils
            openssl
            openssh
          ]
          ++ lib.optionals stdenv.isLinux [ systemd ]
          ++ lib.optionals stdenv.isDarwin [
            lima
            nixos-rebuild-ng
          ]
        )
      }
  '';
}
