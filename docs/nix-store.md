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

Seter deliberately keeps these builds in the guest instead of forwarding the physical host's Nix daemon. Project-controlled derivations therefore execute inside the VM, fixed-output fetches traverse the workspace's DNS and egress policy, and a workspace cannot fill or mutate the host store through Nix. The deployed Runner closure is supplied by its immutable Store View. Other paths that merely happen to exist in the host store are not visible; required development paths are built or substituted into the private layer.

The host store is still part of the trusted boot/runtime supply chain. Every deployed Runner is an explicit dependency of its NixOS system generation; retained system generations therefore retain their matching Runner and Store View for rollback. On boot the guest roots the selected system closure under `/nix/var/nix/gcroots/seter-lower-closures/current`. When that selection changes, it verifies the persistent database after loading the new closure and removes registrations for paths no longer present in the active Store View. This prevents Nix from treating an absent path from an older view as valid; rolling the host generation back loads and registers that generation's closure again.

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

It survives `seter down`, trusted host deployments, and clean-root reboots. Deploying a new Runner does not replace either persistent image.

Normal guest Nix commands work against the overlay:

```console
nix develop
nix build
```

Guest store garbage collection and deletion are deliberately unsupported. Nix scans the merged `/nix/store`, not only the private upper layer. Deleting lower paths records persistent OverlayFS whiteouts in the private image. Those whiteouts can hide a path required by a future Runner even though its immutable Store View was never modified.

Seter sets Nix's automatic free-space collection thresholds to zero, disables the NixOS GC timer, and shadows the normal `nix-collect-garbage`, `nix store gc`, `nix store delete`, `nix-store --gc`, and `nix-store --delete` entry points with a diagnostic refusal. The guard prevents accidents, not hostile guest behavior: project code can invoke the immutable real Nix binary directly, but such code can already corrupt its own private state. If that happens, recover by replacing the private Nix image as described below.

To reclaim a full private store safely, stop the workspace and replace the whole Nix image. Seter does not yet compact only the private upper layer because stock Nix GC cannot distinguish it from the shared lower namespace.

Runner-containing NixOS generations must remain available for as long as their closures are registered in the private Nix image. Removing an old system generation independently can make a lower path disappear beneath a still-valid guest registration. Safe retirement and reset handling remain roadmap work.

If the private Nix image is lost or corrupted, stop the workspace, preserve the old image for diagnosis, and move it out of the workspace state directory. The next boot creates an empty image, reloads the current guest system closure registration, and leaves the separate project volume untouched. Development dependencies then need to be realized again.

Back up this image only if avoiding dependency rebuilds matters. The project volume remains the higher-value backup target.

## Security properties and limits

- The host store is not exported; the Runner's closure-filtered EROFS Store View is read-only.
- Guest Nix builds are sandboxed, but Nix's build sandbox is defense in depth inside the VM rather than a replacement for the VM boundary.
- Build and fetch traffic originates in the guest and remains subject to Seter network policy.
- Only registered runner closures are guaranteed to be reused from the host store; physical presence alone does not register a path in the guest database.
- The fixed-size filesystem bounds store data inside the image, but the host still needs ordinary free-space monitoring for all workspace images.
- A workspace can exhaust its own private store and make its builds fail. It cannot use that image to consume beyond its configured filesystem capacity; recovery currently resets the dependency cache rather than collecting individual paths.
