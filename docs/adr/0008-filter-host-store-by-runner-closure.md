# Filter host-store visibility by Runner closure

A deployed Runner carries a read-only EROFS Store View containing its transitive guest closure rather than exporting the host's `/nix/store`. Retained NixOS generations root their matching Runner and Store View images for rollback. This trades some image storage for a simple fail-closed boundary that cannot expose unrelated project sources or host configuration artifacts; paths built or substituted by project code remain in the workspace's private writable store.
