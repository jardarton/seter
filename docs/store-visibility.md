# Host-store visibility

**Status:** implemented for each deployed Runner; retained NixOS generations retain their corresponding immutable Runner Store Views for rollback.

A workspace must not gain ambient read access to unrelated host-store contents. Read-only access prevents modification, not disclosure: host-store paths can contain source snapshots, configuration artifacts, and other projects even when real secrets are correctly kept out of the store.

## Store View

Each deployed Runner carries a read-only EROFS Store View containing exactly the transitive Nix closure needed to boot that Runner. microvm.nix constructs the image from trusted Nix closure metadata during Runner deployment. The host's `/nix/store` is never shared with the guest.

At boot, the selected Store View and the workspace-private writable overlay appear at the normal guest `/nix/store`. Project dependencies built or substituted later are written only to the private upper store. A workspace can read its boot closure but cannot enumerate another workspace's Runner or arbitrary paths merely present on the host.

Older NixOS generations root their corresponding Runners and Store View images for rollback. Activating a generation selects its matching immutable view; an active VM continues using the view with which it booted. Because the private Nix database persists across that selection, boot reconciles registrations whenever the selected view changes so paths absent from the newly active view are not incorrectly treated as valid. Retirement and garbage collection may remove old generations only under the separate lifecycle rules.

If the filtered image cannot be built or opened, Runner deployment or workspace startup fails. Seter never falls back to exporting the whole host store.

## Security boundary

Filtering reduces confidentiality exposure but does not make Nix store paths secret. The workspace necessarily sees its own Runner closure, including public certificates, scripts, and configuration embedded there. Real credentials remain forbidden from every Nix store closure and are supplied only through host runtime mechanisms.

Closure filtering complements, rather than replaces, the private writable store. The former controls which host paths are visible; the latter prevents project builds from mutating or filling the host store.
