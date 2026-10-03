# Host-store visibility

See the [storage and identity milestone](../ROADMAP.md#2-close-foundational-storage-and-identity-gaps)
for implementation status and evidence.

The host store boundary protects two properties: project code never executes on the host, and a workspace cannot modify or fill the host store. Store contents are not treated as confidential. The Nix store is world-readable to every host account, and real secrets must never enter it. See [ADR 0013](./adr/0013-serve-host-store-as-workspace-nix-cache.md).

A workspace sees host-store paths in two ways: its Runner's boot-time Store View, and on-demand substitution from the [host Nix cache](#host-nix-cache).

## Store View

Each deployed Runner carries a read-only EROFS Store View containing its transitive Nix closure, including any development outputs explicitly approved through `storeSeeds`. microvm.nix constructs the image from trusted Nix closure metadata during Runner deployment. The host's `/nix/store` is never shared with the guest.

At boot, the selected Store View and the workspace-private writable overlay appear at the normal guest `/nix/store`. Project dependencies built or substituted later are written only to the private upper store. The Store View holds only the boot closure and approved seeds, so a workspace boots without depending on the host cache and cannot enumerate other host paths.

Older NixOS generations root their corresponding Runners and Store View images for rollback. Activating a generation selects its matching immutable view; an active VM continues using the view with which it booted. Because the private Nix database persists across that selection, boot reconciles registrations whenever the selected view changes so paths absent from the newly active view are not incorrectly treated as valid. Retirement and garbage collection may remove old generations only under the separate lifecycle rules.

If the filtered image cannot be built or opened, Runner deployment or workspace startup fails. Seter never falls back to exporting the whole host store.

## Host Nix cache

By default the host runs a read-only [Harmonia](https://github.com/nix-community/harmonia) binary cache on loopback and exposes it to every workspace through a `nix-cache` [gateway relay](./network-boundary.md#host-service-relays). Guests list it as their first substituter, ahead of `cache.nixos.org`:

```nix
seter.host.nixCache = {
  enable = true;   # default
  listenPort = 5000; # gateway relay port (default)
  localPort = 5000;  # loopback Harmonia port (default)
};

# Opt one workspace out.
seter.host.workspaces.project.nixCache.enable = false;
```

When guest Nix needs a path that already exists on the host, it copies that path into its private store over the relay instead of rebuilding or downloading it. Development shells built on the host while working on a project are therefore available to its workspace without any per-workspace approval. Paths the host does not have are still built or fetched by the guest under its own network policy.

Properties:

- Harmonia serves only existing valid paths. It has no build, evaluation, or upload interface, so no workspace request runs code on the host or changes the host store.
- A workspace can fetch any host path whose store hash it knows, including another workspace's source snapshots or configuration artifacts. It cannot list the store.
- The guest marks the cache as trusted instead of checking signatures. Only the host can answer on the gateway address because bridge ingress is bound to each TAP's registered MAC and IP; Nix still checks every NAR hash.
- Fetching through the relay is not an exfiltration path: its only endpoint is the trusted host. Exfiltration is limited by [egress policy](./network-boundary.md).

Keep real secrets out of the host store. In particular, never reference a secret through `builtins.readFile`, a `path:` flake that includes untracked key files, or any other store-copying expression.

## Reusing selected development outputs

Trusted consumer configuration can include an already-built development shell or tool in one workspace's Store View:

```nix
seter.host.workspaces.project.storeSeeds = inputs.seter.lib.devShellSeeds {
  devFlake = inputs.project;
  system = pkgs.stdenv.hostPlatform.system;
  # shellName = "tools"; # defaults to "default"
};
```

`storeSeeds` defaults to an empty list. Each approved output and its transitive closure become immutable Runner dependencies, are registered in the guest Nix database at boot, and remain rooted by retained host generations. When the guest requests those exact outputs, it can reuse them without rebuilding or fetching them. New outputs still use the private store. Seeds do not install commands into the guest PATH, approve `.envrc`, change the Guest Profile, or grant network access.

The exported `seter.lib.devShellSeeds` helper selects the development shell
and that flake's own pinned `inputs.nixpkgs.legacyPackages.${system}.bashInteractive`
`out` and `man` outputs. `nix develop` and nix-direnv can request these companions
separately; rooting just the shell may leave them unavailable. Keep the
development flake's own dependency pins instead of substituting the Host's Bash.
For flakes without `inputs.nixpkgs`, the helper returns only the shell; consumers
using another package-set layout must approve its companions explicitly. A
missing shell fails evaluation with a descriptive error.

Seeds only help while the Host's pin of the development flake matches the lock
used inside the Workspace. Changing the workspace lock can request different
outputs that still need guest builds or substitution.

Approval covers the complete transitive closure, including source or configuration paths it references. Select reviewed outputs rather than a host system or broad store inventory. Seter embeds the selected closure in its EROFS image, so reuse avoids guest builds and private-store copies but still consumes host image storage. Updating seeds requires a host deployment and a workspace restart.

With the host Nix cache enabled, seeds are needed only where a path must be present without the cache, for example when it is disabled for that workspace. Selecting a project's development output as a seed evaluates that project's Nix, and can build missing outputs, during trusted host deployment. Prefer the cache for development dependencies so Seter never evaluates project code on the host.

## Security boundary

Nix store paths are not secret. Through its Store View and the host cache, a workspace can read its own Runner closure and any host path whose hash it knows. Real credentials remain forbidden from every Nix store closure and are supplied only through host runtime mechanisms.

The private writable store and the read-only cache together prevent project builds from executing on the host or mutating or filling the host store.
