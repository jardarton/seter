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
`lib`, and `pkgs`, so they can use the registered SSH user. Define these
profiles in the consumer's trusted configuration alongside the Host modules.

### Share packages and configuration with the Host

Keep a common terminal environment in small NixOS and Home Manager modules,
then import those modules into both systems. Each system gets its own package
installation and managed configuration; the Workspace keeps its own Home
Volume and tool state. Reusing a module does not require mounting the Host's
home or copying its dotfiles.

For example, these two files belong in the consumer flake. Their names,
account name, and package selections are illustrative.

`modules/terminal-system.nix`:

```nix
{ pkgs, ... }:
{
  programs.zsh.enable = true;
  environment.systemPackages = [ pkgs.ripgrep ];
}
```

`modules/terminal-home.nix`:

```nix
{ pkgs, ... }:
{
  programs.zsh.enable = true;
  programs.tmux.enable = true;
  home.packages = [ pkgs.jq ];
}
```

The NixOS module enables the login shell and system tools. The Home Manager
module manages the same user-level shell and terminal configuration in each
environment. Additional non-secret program settings or packaged configuration
can live in these shared modules too.

Compose them in the trusted Host configuration. This fragment assumes the
consumer already imports Seter's Host module, registers `project`, creates
the synthetic `operator` account, and supplies `inputs` through its flake
wiring. The consumer supplies its own pinned Home Manager input:

```nix
{ inputs, pkgs, ... }:
let
  terminalSystem = ./modules/terminal-system.nix;
  terminalHome = ./modules/terminal-home.nix;
in
{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    terminalSystem
  ];

  users.users.operator.shell = pkgs.zsh;
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.operator = {
      imports = [ terminalHome ];
      home.stateVersion = "24.11";
    };
  };

  seter.host.guestProfiles.terminal = { config, pkgs, ... }:
    let
      guestUser = config.seter.guest.ssh.user;
    in
    {
      imports = [
        inputs.home-manager.nixosModules.home-manager
        terminalSystem
      ];

      users.users.${guestUser}.shell = pkgs.zsh;
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.${guestUser} = {
          imports = [ terminalHome ];
          home.username = guestUser;
          home.homeDirectory = config.users.users.${guestUser}.home;
          home.stateVersion = "24.11";
        };
      };
    };

  seter.host.workspaces.project.guestProfile = "terminal";
}
```

Use the existing Host account and retain its existing `home.stateVersion`.
For a new guest Home Manager environment, choose its compatibility version
deliberately; the value above is an example, not an instruction to change an
existing installation. The Guest Profile reads the guest's registered account
instead of capturing the Host's user name or home directory.

Home Manager is optional; a shared NixOS module alone is sufficient for system
packages and system-level configuration. `guestPackages` remains convenient
for a Workspace that only needs extra packages. `storeSeeds` roots approved
closures for reuse but does not install commands or configure the shell.

### Keep package selection reproducible

Pin tool inputs in the consumer flake and use the same package definitions or
wrapper factories in both evaluations. Shared modules should use their own
`pkgs` argument, and input-provided packages should select
`pkgs.stdenv.hostPlatform.system`. This allows the same definitions to produce
packages for each target architecture without capturing a package built for a
different system.

Seter evaluates Guests separately from the Host. Host `nixpkgs.overlays`,
`nixpkgs.config`, `specialArgs`, and Home Manager `extraSpecialArgs` do not
automatically carry into that evaluation. If a shared tool needs an overlay or
package policy, put it in a small NixOS module imported by both the Host and
the Guest Profile. Capture pinned inputs explicitly in the profile or pass
them to its Home Manager modules through `home-manager.extraSpecialArgs`.

`home-manager.useGlobalPkgs = true` uses each system's own NixOS package set,
including that system's overlays. It does not make the Guest inherit the
Host's package set. With matching inputs, overrides, and target system, common
derivations can reuse store paths; different architectures require separate
builds. With `useUserPackages = true`, guest user packages are included in the
Runner closure and Store View.

### Adapt the environment without copying Host authority

Share the headless tools and managed configuration that the Workspace needs.
Compose desktop features, Host login behavior, deployment commands, local
paths, and account-specific settings separately. Settings that vary by role
can use `lib.mkDefault` in the shared module and ordinary assignments in the
Host or Guest adapter. Terminal launch hooks should leave `seter shell` and
`seter run` able to enter the registered checkout and execute the requested
command.

Do not import an entire machine configuration or a credential-bearing user
profile into the Guest. Package and configuration reuse grants no extra
network access; required destinations still need trusted Policy Grants, and
real credentials remain on the Host.

### Deploy and update the shared environment

Changing a shared module requires the consumer's normal trusted Host
deployment to rebuild the selected Runners. A running Workspace uses the new
profile when its deployed Runner is activated; deployment may restart it.
Project development flakes still execute inside the Workspace through normal
Nix and direnv use.

Home Manager writes managed dotfiles into the persistent Home Volume during
boot activation. Subsequent boots update them, and a Home reset recreates them
from the deployed profile. Consumers must verify activation ordering and handle
pre-existing files when adopting Home Manager on an existing Home Volume.
History, logins, and unmanaged state remain local to that Workspace.

After deployment, check `seter shell project` for the selected shell and tools,
and use `seter run project -- <command>` to check non-interactive operation.
For a disposable Workspace, stop it with `seter down project`, reset Home with
`seter reset project --home`, and enter a shell again. Verify that managed
configuration returns, while prior approvals and history do not.

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
