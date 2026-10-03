# Private writable Nix stores

Seter guests combine two storage layers at `/nix/store`:

- the Runner's closure-filtered EROFS [Store View](./store-visibility.md), mounted read-only at `/nix/.ro-store`;
- a workspace-private ext4 image mounted at `/nix`, with microvm.nix using `/nix/.rw-store` as the overlay upper and work directory.

The same private image retains `/nix/var/nix`, including the guest Nix database, profiles, and GC state. The VM root remains tmpfs and the project tree remains on its separate project image.

```text
Runner Store View (read-only EROFS lower)
                      +
<workspace>-nix-store.img (/nix/.rw-store upper)
                      |
                      v
guest /nix/store (writable overlay)
```

## Why the writable layer is private

Interactive development must be able to realize paths after a flake or lock-file change. A conventional remote builder or substituter normally copies its result into the requesting machine's store, so neither makes a read-only guest store sufficient by itself.

Seter deliberately keeps these builds in the guest instead of forwarding the physical host's Nix daemon. Project-controlled derivations therefore execute inside the VM, fixed-output fetches traverse the workspace's DNS and egress policy, and a workspace cannot fill or mutate the host store through Nix. The deployed Runner closure, including explicitly approved [store seeds](./store-visibility.md#reusing-selected-development-outputs), is supplied by its immutable Store View. Other paths are substituted into the private layer, first from the read-only [host Nix cache](./store-visibility.md#host-nix-cache) when the host already has them, or built or fetched by the guest.

The host store is still part of the trusted boot/runtime supply chain. Every deployed Runner is an explicit dependency of its NixOS system generation; retained system generations therefore retain their matching Runner and Store View for rollback. On boot the guest roots the selected system closure under `/nix/var/nix/gcroots/seter-lower-closures/current` and registers that closure in the persistent database. Rolling the host generation back therefore registers that generation's closure again.

### Store View changes

Paths substituted into or built in the private layer can depend on paths that only the booted Store View supplied, because Nix does not copy a dependency that is already valid. A Runner change can remove such a dependency from the next view. Nix keeps an absent path registered while any valid path refers to it; the dependent then fails at runtime, and Nix never substitutes the absent path again. `nix-store --verify` cannot clean this up: when an absent path's only referrers are themselves absent but still needed, it tries to invalidate the path anyway and aborts on the database's foreign-key constraint.

After the selected Runner changes, `seter-nix-store-repair.service` therefore runs once the guest network is up:

1. Each absent path that a present path still needs, directly or through other absent paths, is substituted again with `nix-store --repair-path`, normally from the host Nix cache. Repair never builds, because rebuilding from a deriver could compile a whole toolchain during boot.
2. Every path that is still absent is deleted together with its dependents. This removes registrations nothing needs, and makes Nix substitute or build unrepairable dependents again on demand rather than trusting them. The service refuses to delete any path present in the active Store View, which would otherwise leave a whiteout.
3. The service records the booted view in `/nix/var/nix/seter-store-view` only after no absent path remains registered. A failed or interrupted repair runs again on the next boot.

Builds started before the service finishes can still encounter absent dependencies.

## Configuration

The trusted registry owns image identity and initial capacity so the host and Runner cannot drift:

```nix
seter.host.workspaces.project.storage.nixStore = {
  image = "project-nix-store.img"; # default
  sizeMiB = 16384;                 # default
};
```

The generated module requires:

- `seter.guest.nixStore.enable = true`;
- the registered image name and capacity;
- `microvm.writableStoreOverlay = "/nix/.rw-store"`;
- an ext4 volume mounted at `/nix` during the initrd;
- sandboxed Nix builds;
- store optimisation disabled, as required by microvm.nix for overlay stores;
- automatic and normal command-line guest store garbage collection disabled.

The low-level guest options are `seter.guest.nixStore.image` and `seter.guest.nixStore.size`; normal workspaces configure only the trusted host registry.

`size` is the capacity used when microvm.nix first creates the sparse image. Changing it does not resize an existing filesystem. Stop the workspace and use an explicit, reviewed ext4 image-resize procedure before changing an existing deployment; Seter does not automate shrinking or expansion yet.

## Lifecycle and recovery

The image lives beside the project image under:

```text
/var/lib/seter/workspaces/<workspace>/
```

It survives `seter down`, trusted host deployments, and clean-root reboots. Deploying a new Runner does not replace the persistent volumes.

Normal guest Nix commands work against the overlay:

```console
nix develop
nix build
```

Guest store garbage collection and deletion are deliberately unsupported. Nix scans the merged `/nix/store`, not only the private upper layer. Deleting lower paths records persistent OverlayFS whiteouts in the private image. Those whiteouts can hide a path required by a future Runner even though its immutable Store View was never modified.

Seter sets Nix's automatic free-space collection thresholds to zero, disables the NixOS GC timer, and shadows the normal `nix-collect-garbage`, `nix store gc`, `nix store delete`, `nix-store --gc`, and `nix-store --delete` entry points with a diagnostic refusal. The guard prevents accidents, not hostile guest behavior: project code can invoke the immutable real Nix binary directly, but such code can already corrupt its own private state. If that happens, recover by replacing the private Nix image as described below.

To reclaim a full private store safely, stop the workspace and replace the whole Nix image. Seter does not yet compact only the private upper layer because stock Nix GC cannot distinguish it from the shared lower namespace.

Retained NixOS generations root their matching Runners and Store Views. On a
change of Store View, guest boot reconciles persistent registrations with paths
actually present in that view. See [Host-store visibility](./store-visibility.md).

If the private Nix image is corrupted or full, stop the Workspace and preserve
the image privately if diagnosis is needed. Use `seter reset <workspace>
--nix-store` to replace this cache without touching Project data. The next boot
loads the current guest system closure and approved store seeds; other
development dependencies must be realized again, from the host Nix cache where
the host still has them. See [storage lifecycle](./storage-lifecycle.md).

Back up this image only if avoiding dependency rebuilds matters. The project volume remains the higher-value backup target.

## Security properties and limits

- The host store is never mounted or writable; the Runner's closure-filtered EROFS Store View is read-only, and the host Nix cache serves existing paths read-only without building anything.
- Guest Nix builds are sandboxed, but Nix's build sandbox is defense in depth inside the VM rather than a replacement for the VM boundary.
- Build and fetch traffic originates in the guest and remains subject to Seter network policy.
- Host paths enter the guest database only through the Store View or by substitution into the private store; physical presence on the host alone does not register a path.
- The fixed-size filesystem bounds store data inside the image, but the host still needs ordinary free-space monitoring for all workspace images.
- A workspace can exhaust its own private store and make its builds fail. It cannot use that image to consume beyond its configured filesystem capacity; recovery currently resets the dependency cache rather than collecting individual paths.
