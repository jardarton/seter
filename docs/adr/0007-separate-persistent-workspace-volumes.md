# Separate persistent workspace volumes

Each workspace uses separate Project, Home, and private Nix-store volumes so normal user state survives clean-root reboots while reproducible state can be reset without risking the working tree. `seter reset` may replace the Home or private Nix-store volume only while the workspace is stopped, and even `--all-state` excludes the Project Volume; this costs an additional block image and mount wiring but makes cleanup boundaries mechanically clear rather than dependent on recursive deletion inside one mixed filesystem.

The Project Volume contains all of a Workspace's repository checkouts. A
repository collection does not introduce per-repository volumes: these would
add lifecycle complexity without isolating code inside the same guest. Registry
removal retains checkout data, and explicit Project Volume destruction removes
every checkout. See [ADR 0011](./0011-workspaces-contain-repository-collections.md).
