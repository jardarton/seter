# Consumer-owned policy file

Seter records Policy Grants in a dedicated consumer-owned TOML Policy File rather than editing arbitrary Nix expressions or maintaining mutable runtime exceptions. `seter policy review` may update that file only after explicit operator review, while the consumer reviews its version-control diff and deploys it through normal NixOS configuration; this keeps default-deny policy iteration usable without allowing observations to become authority automatically or hiding permanent grants outside declarative state.
