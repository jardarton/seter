# Trusted consumer Guest Profiles

This refines [ADR 0003](0003-trusted-guest-profile-default.md): ordinary
repositories still supply development flakes, while trusted consumer infra can
now define named Guest Profiles through `seter.host.guestProfiles` and select
one per Workspace. `default` remains reserved for Seter's built-in baseline.

Each consumer profile is a NixOS module evaluated in the same guest system as
the default profile and the generated Runner identity module. It can read guest
configuration, including the registered SSH user, and install shells, dotfiles,
Home Manager, agents, and guest services. The consumer owns module imports;
Seter has no Home Manager dependency. `guestPackages` and `storeSeeds` retain
their existing meanings.

Profiles are trusted host configuration, never modules loaded from the workload
repository. They are not an “extension only” interface. Existing assertions
reject conflicting identity, network, firewall, volume, SSH, proxy, placeholder,
and Nix-store settings. They guard Seter's declarative invariants; they do not
sandbox module code. A trusted profile can still run arbitrary root services or
activation scripts inside the guest. Host enforcement remains authoritative.

Names use ASCII letters, digits, underscores, dots, and hyphens, starting with a
letter or digit. Unknown selections fail evaluation. The selected name stays in
both the lifecycle registry and Runner identity; the CLI requires those names
to match. Changing profile contents requires trusted Runner deployment, even
when its name stays the same.

Evaluation coverage verifies a consumer shell/package profile, baseline tooling,
unknown and reserved names, and rejection of protected overrides. Runtime Home
Manager activation is consumer responsibility: managed dotfiles live on the
persistent Home Volume and are recreated on boot after a Home reset. Never put
secrets, secret files, or host sops runtime paths into a Guest Profile or its
closure. Use Seter's host credential bindings and non-secret placeholders.
