# Local repository import

Use an explicitly local source for a repository that has no HTTPS remote:

```nix
seter.host.workspaces.project.repositories.project = {
  local = true;
  # branch = "main"; # optional initial branch selection
};
```

A local entry has no `url` or repository `credential`. It grants no repository
hostname, DNS access, or credential authority. Normal resource, storage, SSH,
and Guest Profile configuration still applies. Deploy the registry and CLI
together: local sources use lifecycle registry version 8.

Create a self-contained bundle from the selected source repository:

```console
git -C ./project bundle create ../project.bundle --all
seter import project --bundle ../project.bundle
```

`import` selects `--repo`, the configured default, or the sole repository.
It requires a local registry entry, starts the deployed Runner, verifies the
host-created SSH identity, and streams the bundle to the guest. The host does
not evaluate source Nix, mount the source directory, copy Git configuration or
hooks, approve `.envrc`, or grant access to a local Git service.

The guest validates bundle prerequisites in an empty repository, creates a
temporary checkout on the Project Volume, retains bundled branches and tags,
removes its temporary origin, and publishes the checkout without replacing
existing data. A configured branch overrides the bundle's default HEAD.
Invalid or incremental-only bundles fail without publishing a checkout.
Existing paths, including empty directories and symlinks, are rejected.
Interrupted imports may require inspection of a retained staging directory
after a VM or connection failure; they never justify clearing a checkout.

`seter init` verifies an existing local import without fetching or changing
its branch, index, or dirty files. Before import it reports the required
`seter import` action. Repeated import refuses to overwrite even a clean
checkout. Updating local code is an explicit Git/file transfer, not a reset.

Bundles carry committed Git objects and references, not uncommitted changes,
untracked files, ignored media, submodule repositories, or linked worktree
metadata. Transfer selected working files separately, initialize approved
submodules, and recreate worktrees inside `/project`. Do not copy linked
worktrees' `.git` files: they refer to paths outside the guest. Keep writable
build output separate per worktree. Review and approve each `.envrc` explicitly
before running its development environment.
