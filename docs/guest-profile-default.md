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

## Trusted consumer profiles

Trusted host configuration can define reusable NixOS modules in
`seter.host.guestProfiles` and select one with a Workspace's `guestProfile`.
Every custom profile is layered on the built-in default profile in the same
guest evaluation. Names start with an ASCII letter or digit and contain only
ASCII letters, digits, underscores, dots, or hyphens. `default` is reserved;
unknown names fail evaluation. Profile modules receive the guest's `config`,
`lib`, and `pkgs`, so they can use the registered SSH user:

```nix
# The consumer flake supplies its own Home Manager input.
seter.host.guestProfiles.terminal = { config, pkgs, ... }: {
  imports = [ inputs.home-manager.nixosModules.home-manager ];
  programs.zsh.enable = true;
  users.users.${config.seter.guest.ssh.user}.shell = pkgs.zsh;
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${config.seter.guest.ssh.user} = {
      home.stateVersion = "24.11";
      programs.zsh.enable = true;
      programs.git.enable = true;
      home.packages = [ pkgs.tmux ];
    };
  };
};
seter.host.workspaces.project.guestProfile = "terminal";
```

Seter does not depend on Home Manager. With `home-manager.useUserPackages =
true`, user packages land in the Runner closure and Store View. Home Manager
writes managed dotfiles into the persistent Home Volume during boot activation;
subsequent boots update them, and a Home reset recreates them from the deployed
profile. Consumers must verify activation ordering and handle pre-existing
files when adopting Home Manager on an existing Home Volume.

Consumer modules are trusted host configuration, not repository code and not
“extension only.” Seter's existing assertions guard declarative identity,
networking, firewall, volumes, SSH, proxy, placeholders, and Nix-store
invariants. A trusted profile can still run arbitrary guest services and
activation scripts. Never put secrets or sops paths in a guest profile. Runtime
credentials stay on the Host; guests receive only destination-bound non-secret
placeholders. See [ADR 0012](adr/0012-trusted-consumer-guest-profiles.md).

## Evidence

Evaluation checks verify the flake features, CA support, and direnv/nix-direnv
integration in the generated guest. The nested-KVM lifecycle check copies a
fixture repository containing only `flake.nix` and `.envrc`, proves activation
is initially denied, explicitly approves it, enters its development shell, and
verifies the approval survives a restart.
