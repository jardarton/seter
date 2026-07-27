# Private writable Nix stores

> **Current implementation warning:** the vertical slice exports the host's entire `/nix/store`, so guests can read unrelated host-store source and configuration artifacts. The accepted product design replaces this with a closure-filtered workspace [Store View](./store-visibility.md); it is not yet implemented.

Seter guests currently combine two storage layers at `/nix/store`:

- the host `/nix/store`, exported by host-owned virtiofsd and mounted read-only at `/nix/.ro-store`;
- a workspace-private ext4 image mounted at `/nix`, with microvm.nix using `/nix/.rw-store` as the overlay upper and work directory.

The same private image retains `/nix/var/nix`, including the guest Nix database, profiles, and GC state. The VM root remains tmpfs and the project tree remains on its separate project image.

```text
host /nix/store (read-only VirtioFS lower)
                      +
<workspace>-nix-store.img (/nix/.rw-store upper)
                      |
                      v
guest /nix/store (writable overlay)
```

## Why the writable layer is private

Interactive development must be able to realize paths after a flake or lock-file change. A conventional remote builder or substituter normally copies its result into the requesting machine's store, so neither makes a read-only guest store sufficient by itself.

Seter deliberately keeps these builds in the guest instead of forwarding the physical host's Nix daemon. Project-controlled derivations therefore execute inside the VM, fixed-output fetches traverse the workspace's DNS and egress policy, and a workspace cannot fill or mutate the host store through Nix. The registered closure of every runner the workspace has booted remains shared without duplication. Other paths that merely happen to exist in the host store are not automatically valid in the guest's separate Nix database and may be rebuilt or substituted into the private layer.

The host store is still part of the trusted boot/runtime supply chain. Seter retains a host GC root for every installed runner generation under `/nix/var/nix/gcroots/per-project/.runner-history/<workspace>/`. On each boot the guest creates a matching permanent root for its system closure under `/nix/var/nix/gcroots/seter-lower-closures/`. Together these roots keep previously registered runner closures present across upgrades and rollbacks. The roots consume negligible private-image space, while their referenced closures remain deduplicated in the host store.

## Configuration

`mkWorkspaceDefinition` owns the image identity and initial capacity so the host registry and generated guest module cannot drift:

```nix
project = seter.lib.mkWorkspaceDefinition {
  name = "project";
  # ...network and runner identity...
  nixStoreImage = "project-nix-store.img"; # default
  nixStoreSizeMiB = 16384;                 # default
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

The low-level guest options are `seter.guest.nixStore.image` and `seter.guest.nixStore.size`. Security-sensitive workspaces should use `mkWorkspaceDefinition` rather than configuring those independently.

`size` is the capacity used when microvm.nix first creates the sparse image. Changing it does not resize an existing filesystem. Stop the workspace and use an explicit, reviewed ext4 image-resize procedure before changing an existing deployment; Seter does not automate shrinking or expansion yet.

## Lifecycle and recovery

The image lives beside the project image under:

```text
/var/lib/seter/workspaces/<workspace>/
```

It survives `seter down`, runner updates, and clean-root reboots. `seter update` changes the current immutable runner and adds its history root; it does not replace either persistent image.

Normal guest Nix commands work against the overlay:

```console
nix develop
nix build
```

Guest store garbage collection and deletion are deliberately unsupported. Nix scans the merged `/nix/store`, not only the private upper layer. It therefore treats unrelated, unregistered paths visible in the host lower store as garbage; deleting them records persistent OverlayFS whiteouts in the private image. Those whiteouts can hide a path required by a future runner even though the host copy was never modified.

Seter sets Nix's automatic free-space collection thresholds to zero, disables the NixOS GC timer, and shadows the normal `nix-collect-garbage`, `nix store gc`, `nix store delete`, `nix-store --gc`, and `nix-store --delete` entry points with a diagnostic refusal. The guard prevents accidents, not hostile guest behavior: project code can invoke the immutable real Nix binary directly, but such code can already corrupt its own private state. If that happens, recover by replacing the private Nix image as described below.

To reclaim a full private store safely, stop the workspace and replace the whole Nix image. Seter does not yet compact only the private upper layer because stock Nix GC cannot distinguish it from the shared lower namespace.

Runner-history roots must remain for as long as the private Nix image is retained. Removing one independently can make a lower path disappear beneath a still-valid guest registration. A future `seter gc` implementation must therefore remove history only together with resetting or inspecting the workspace's private Nix state; deleting arbitrary history roots by hand is unsafe.

If the private Nix image is lost or corrupted, stop the workspace, preserve the old image for diagnosis, and move it out of the workspace state directory. The next boot creates an empty image, reloads the current guest system closure registration, and leaves the separate project volume untouched. Development dependencies then need to be realized again.

Back up this image only if avoiding dependency rebuilds matters. The project volume remains the higher-value backup target.

## Security properties and limits

- The host VirtioFS export remains read-only.
- Guest Nix builds are sandboxed, but Nix's build sandbox is defense in depth inside the VM rather than a replacement for the VM boundary.
- Build and fetch traffic originates in the guest and remains subject to Seter network policy.
- Only registered runner closures are guaranteed to be reused from the host store; physical presence alone does not register a path in the guest database.
- The fixed-size filesystem bounds store data inside the image, but the host still needs ordinary free-space monitoring for all workspace images.
- A workspace can exhaust its own private store and make its builds fail. It cannot use that image to consume beyond its configured filesystem capacity; recovery currently resets the dependency cache rather than collecting individual paths.
