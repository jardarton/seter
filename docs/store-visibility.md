# Host-store visibility

**Status:** accepted product design; not yet implemented. The current vertical slice exports the host's entire `/nix/store` read-only and therefore does not satisfy this visibility boundary.

A workspace may share host Nix store paths needed to boot its Runner, but must not gain ambient read access to unrelated host-store contents. Read-only access prevents modification, not disclosure: host-store paths can contain source snapshots, configuration artifacts, and other projects even when real secrets are correctly kept out of the store.

## Store View

Each workspace receives a Store View containing only the transitive Nix closure of:

- its currently deployed Runner; and
- any explicitly retained Runner generations needed for that workspace's rollback and persistent guest-database contract.

The host computes closure membership from trusted Nix store metadata. It constructs a workspace-specific read-only filesystem view and exports that view through the workspace's host-owned VirtioFS service. The VirtioFS root must not expose the host store root, paths outside the selected closure, or host symlink traversal outside the view.

At boot, the selected lower closure and the workspace-private writable overlay appear at the normal guest `/nix/store`. Project dependencies built or substituted later are written only to the private upper store. A workspace can read its own current and retained boot closures, but cannot enumerate another workspace's unrelated Runner or arbitrary paths merely present on the host.

## Lifecycle

The Store View is constructed from host-deployed and rooted Runner generations. Runner deployment updates the closure set for the next cold boot; an active VM continues using the view associated with its booted Runner. Retirement and garbage collection may remove generations only after they are no longer required by active or retained workspace state.

If Seter cannot construct a complete filtered view, workspace startup fails. It must never fall back to exporting the whole host store.

## Security boundary

Filtering reduces confidentiality exposure but does not make Nix store paths secret. The workspace necessarily sees its own Runner closure, including public certificates, scripts, and configuration embedded there. Real credentials remain forbidden from every Nix store closure and are supplied only through host runtime mechanisms.

Closure filtering complements, rather than replaces, the private writable store. The former controls which host paths are visible; the latter prevents project builds from mutating or filling the host store.
