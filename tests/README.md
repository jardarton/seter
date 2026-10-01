# Tests

Run the complete suite with `nix flake check`. For a focused check:

```console
scripts/run-captured --log-name workspace-registry -- \
  nix build .#checks.x86_64-linux.workspace-registry
```

`parts/checks.nix` contains wiring. Each Nix scenario owns its configuration and
assertions; shared synthetic configurations live in `fixtures/`.

- `configuration-validation.nix` checks rejected configurations. Valid host and
  guest baselines must pass, and generated guest overrides are tested separately
  so one broken setting cannot mask another.
- `workspace-registry.nix` checks module contracts and runs `registry-projections.py`
  and `workspace-cli.py`: deployed manifest agreement, secret-path exclusion,
  registry queries, stale Runner rejection, and confirmed or declined policy review.
- `status-snapshot.py`, `privilege.py`, `policy-ownership.nix`, and
  `host-patterns.nix` cover their respective behavior contracts.
- VM scenarios cover real sudo authorization, service failure handling, network
  isolation, credential injection and redaction, revocation, guest trust, and the
  lifecycle of persistent volumes. `lifecycle-e2e.nix` requires nested KVM.

The Python CLI tests accept a built binary and generated synthetic fixtures as
positional arguments; see their module docstrings. Run them as a non-root user.
Policy review must change the complete parsed policy only after confirmation,
and a declined write must preserve the original bytes.
