# Trusted `default` Guest Profile

**Status:** implemented. This is the only public Guest Profile in the first
usable milestone.

The host builds every registered `default` Runner from trusted Seter code. A
repository supplies only its normal development flake and optional `.envrc`;
it does not supply NixOS modules or Seter-specific guest configuration.

## Profile contract

The profile provides:

- flake-enabled Nix and Seter's persistent private writable-store machinery;
- Git, curl, and the NixOS system CA bundle, including the configured public
  Seter interception CA;
- the OpenSSH client and Seter's strictly configured guest SSH server;
- direnv and nix-direnv with Bash prompt integration; and
- Bash plus a small baseline of standard file, text, archive, process, and
  filesystem utilities.

The baseline is intentionally not a project toolchain. Compilers, language
runtimes, editors, agents, and project-specific commands belong in the
repository's development flake or, in the future, a trusted consumer-owned
profile. Seter core does not package an agent.

`.envrc` files remain untrusted repository code. The profile installs the
shell hook but does not approve an `.envrc`; the user must run `direnv allow`
explicitly. Approval and nix-direnv caches persist in the workspace's Home and
Project Volumes respectively.

## Evidence

Evaluation checks verify the flake features, CA support, and direnv/nix-direnv
integration in the generated guest. The nested-KVM lifecycle check copies a
fixture repository containing only `flake.nix` and `.envrc`, proves activation
is initially denied, explicitly approves it, enters its development shell, and
verifies the approval survives a restart.
