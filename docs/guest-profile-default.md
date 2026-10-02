# Trusted `default` Guest Profile

See the [`default` Guest Profile milestone](../ROADMAP.md#3-implement-the-trusted-default-guest-profile)
for implementation status and evidence.

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
runtimes and project-specific commands belong in the repository's development
flake. Trusted consumer configuration can install editors, agents, and other
workspace-wide tools through `seter.host.workspaces.<name>.guestPackages`:

```nix
seter.host.workspaces.project.guestPackages = [
  pkgs.tmux
  pkgs.ripgrep
];
```

This list defaults to empty and extends the selected Guest Profile's system
packages. Its closures enter the immutable Runner and read-only Store View;
unlike `storeSeeds`, these packages also enter the guest's system PATH. Changes
require a trusted host deployment, which can restart the workspace. Tool state
and logins remain in the persistent Home Volume. Packages do not grant network
access or import host user configuration. Seter core does not package an agent.

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
