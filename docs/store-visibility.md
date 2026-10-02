# Host-store visibility

See the [storage and identity milestone](../ROADMAP.md#2-close-foundational-storage-and-identity-gaps)
for implementation status and evidence.

A workspace must not gain ambient read access to unrelated host-store contents. Read-only access prevents modification, not disclosure: host-store paths can contain source snapshots, configuration artifacts, and other projects even when real secrets are correctly kept out of the store.

## Store View

Each deployed Runner carries a read-only EROFS Store View containing its transitive Nix closure, including any development outputs explicitly approved through `storeSeeds`. microvm.nix constructs the image from trusted Nix closure metadata during Runner deployment. The host's `/nix/store` is never shared with the guest.

At boot, the selected Store View and the workspace-private writable overlay appear at the normal guest `/nix/store`. Project dependencies built or substituted later are written only to the private upper store. A workspace can read its boot closure and approved seeds but cannot enumerate another workspace's Runner or arbitrary paths merely present on the host.

Older NixOS generations root their corresponding Runners and Store View images for rollback. Activating a generation selects its matching immutable view; an active VM continues using the view with which it booted. Because the private Nix database persists across that selection, boot reconciles registrations whenever the selected view changes so paths absent from the newly active view are not incorrectly treated as valid. Retirement and garbage collection may remove old generations only under the separate lifecycle rules.

If the filtered image cannot be built or opened, Runner deployment or workspace startup fails. Seter never falls back to exporting the whole host store.

## Reusing selected development outputs

Trusted consumer configuration can include an already-built development shell or tool in one workspace's Store View:

```nix
seter.host.workspaces.project.storeSeeds = [
  inputs.project.devShells.${pkgs.system}.default
  # nix develop may request this separately from the development-shell output.
  inputs.project.inputs.nixpkgs.legacyPackages.${pkgs.system}.bashInteractive
  inputs.project.inputs.nixpkgs.legacyPackages.${pkgs.system}.bashInteractive.man
];
```

`storeSeeds` defaults to an empty list. Each approved output and its transitive closure become immutable Runner dependencies, are registered in the guest Nix database at boot, and remain rooted by retained host generations. When the guest requests those exact outputs, it can reuse them without rebuilding or fetching them. New outputs still use the private store. Seeds do not install commands into the guest PATH, approve `.envrc`, change the Guest Profile, or grant network access.

Keep the development flake's own dependency pins when selecting these outputs. If they differ from the guest baseline, include companion outputs requested by the development tools, such as the pinned interactive Bash used by `nix develop`. Include the outputs tooling installs: `nix develop` can request Bash's manual output alongside its executable output, while a single package seed roots only its selected output.

Approval covers the complete transitive closure, including source or configuration paths it references. Select reviewed outputs rather than a host system or broad store inventory. Seter embeds the selected closure in its EROFS image, so reuse avoids guest builds and private-store copies but still consumes host image storage. Updating seeds requires a host deployment and a workspace restart.

## Security boundary

Filtering reduces confidentiality exposure but does not make Nix store paths secret. The workspace necessarily sees its own Runner closure, including public certificates, scripts, and configuration embedded there. Real credentials remain forbidden from every Nix store closure and are supplied only through host runtime mechanisms.

Closure filtering complements, rather than replaces, the private writable store. The former controls which host paths are visible; the latter prevents project builds from mutating or filling the host store.
