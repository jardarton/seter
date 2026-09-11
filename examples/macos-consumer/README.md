# Minimal macOS consumer flake

This directory is an external-style, consumer-owned configuration for one
`aarch64-linux` Seter Host. Copy it into the Client Exchange Directory; do not
make the Seter repository itself your site configuration.

See [deployment](../../docs/macos-deployment.md) and the
[operator workflow](../../docs/macos-workflow.md). Names, addresses, and the
destroyed-key fixture here are examples, not a captured machine configuration.
Keep your replacement keys, certificates, and site settings in this consumer
copy, never in Seter's source tree.

Before deployment:

1. Create the Lima instance, then set `operatorName` in `host.nix` to the
   actual bootstrap account reported by `limactl shell seter -- id -un`.
   Lima substitutes `lima` when the macOS account name is not a valid Linux
   user name, so the macOS result of `id -un` is not authoritative.
2. Replace `operator-key.pub` with a public key whose private key is loaded in
   the macOS SSH agent. The checked-in key is deliberately unusable because its
   private half was destroyed.
3. Replace the example Workspace Registry entry and review `policy.toml`.
4. Pin the inputs with `nix flake lock`. The example follows Seter's tested
   nixpkgs revision rather than independently tracking `nixos-unstable`.
   During development of an unmerged Seter checkout, set `inputs.seter.url`
   to `path:/absolute/path/to/seter`.

From the Seter checkout on the macOS Client:

```sh
nix run path:.#macos-host -- create "$HOME/seter-exchange"
nix run path:.#macos-host -- deploy "$HOME/seter-exchange/consumer" seter-host
```

The first deployment creates the Host's persistent interception CA. Before
starting the example Workspace, export its public certificate into the
consumer flake, review it, uncomment `proxyCaCertificate` in `host.nix`, and
redeploy:

```sh
limactl shell seter -- seter proxy-ca \
  > "$HOME/seter-exchange/consumer/proxy-ca-cert.pem"
nix run path:.#macos-host -- deploy "$HOME/seter-exchange/consumer" seter-host
```

The deploy command evaluates the consumer flake on macOS but passes all Linux
builds to the Seter Host. The configuration imports only
`seter.nixosModules.limaHost`; that module composes Lima guest support with the
ordinary Seter Host module and the accepted ARM QEMU/KVM defaults.

The consumer still owns users, authorized keys, Workspace Registry entries,
Policy Grants, credentials, resource allocations, and `system.stateVersion`.
