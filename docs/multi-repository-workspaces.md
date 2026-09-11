# Multi-repository workspaces

A Workspace is the isolation boundary, not a repository. Group related
repositories when they should share a VM, user home, Nix store, resource limits,
and policy. All code in that Workspace can modify its other checkouts and
exercise its granted credentials and network capabilities. Use separate
Workspaces for separate trust boundaries.

## Declare repositories

In an otherwise configured Workspace:

```nix
seter.host.workspaces.product = {
  repositories = {
    frontend.url = "https://git.example/team/frontend.git";
    backend = {
      url = "https://git.example/team/backend.git";
      branch = "main";
      credential = "backendToken";
    };
  };
  defaultRepository = "frontend";
  secrets.backendToken = {
    repositoryOnly = true;
    placeholder = "seter-placeholder-backend-0123456789abcdef";
    sourceFile = "/run/secrets/product-backend-token";
    hosts = [ "git.example" ];
    headers = [ "authorization" ];
  };
};
```

Repository keys are stable CLI identifiers and default directory names:
`/project/frontend` and `/project/backend`. `checkoutName` can override a
directory without changing the CLI identifier. Names must start with an ASCII
letter or digit and contain only ASCII letters, digits, underscores, dots, and
hyphens. Directories must be unique within the Workspace; nested paths and
symlinks are not supported as managed checkout targets. At least one
repository is required. Every URL must use HTTPS on port 443.

The Guest Profile, SSH identity, volumes, resources, policy grants, and VM
lifecycle remain Workspace-wide. Repository code never participates in
building the trusted Runner. Repository hosts are automatically granted DNS
and intercepted HTTP access; they must not also be TLS-passthrough hosts.
Enroll the reviewed proxy CA before using HTTPS bootstrap.

## Daily workflow

```console
seter init product
seter init product --repo backend
seter shell product --repo backend
seter run product --repo backend -- cargo test
seter shell product --root
seter down product
```

- `init` initializes all repositories in key order, or just `--repo`. It
  establishes VM/SSH readiness once. A failed checkout does not roll back
  successful clones or prevent attempts on the remaining repositories. Any
  repository failure returns exit status 1 with per-repository diagnostics;
  transport setup errors may abort the operation. The VM stays running.
- `shell` and `run` use `--repo`, then `defaultRepository`, then the sole
  repository. With several repositories and no default they refuse to guess
  and list the available keys. An unknown selector fails before starting the VM.
- `shell --root` enters `/project`, without selecting a repository environment.
  It conflicts with `--repo`. This is useful for cross-repository agent work.
- `run` loads only the selected checkout's direnv environment. Review and
  approve each `.envrc` separately in its repository shell. Seter never
  automatically approves code or merges development environments. Normal
  direnv parent-directory inheritance still applies to user-created `.envrc`
  files above checkouts.
- `up`, `down`, `status`, `reset`, and `audit` remain Workspace-scoped.
  There is no implicit command fan-out across repositories.

## Credentials and removal

Named repositories require `repositoryOnly = true` on their credential
bindings. This keeps a retained binding denied even after its final repository
association is removed, rather than silently making it host-wide. Generic API
bindings retain their existing host/header policy with `repositoryOnly = false`.

A credential may be associated with several repositories explicitly. Its
allowed destinations are the union of their exact hosts and Git HTTP paths;
every host must also appear in the binding's `hosts`. Prefer separate,
least-privilege service-side tokens where possible. A repository-local Git
placeholder is not an isolation boundary against other code in the same VM.

Exact path checks restrict **credential injection**, not every HTTP request.
Public repositories on an allowed Git host may still be reachable without a
credential. Removing a source from the registry is not a promise that all
unauthenticated access to it is blocked.

Add a repository by deploying trusted configuration and running `init` again.
Existing matching checkouts are retained, including dirty changes. Initial
branch selection does not switch existing complete checkouts.

Remove a repository by removing its declaration and adjusting the default and
unused secrets/grants before deployment. This removes its credential association
but never deletes its checkout. If retaining an unused repository-only secret,
its hosts must still satisfy normal intercepted-host validation. Changing a
registered URL at an occupied checkout is rejected if `origin` differs; move
the old checkout aside explicitly or choose a new checkout name.

All repositories share the Project Volume's capacity. Home and private-store
resets affect all repositories, but never remove Project data. **`destroy-project`
deletes the entire Project Volume**, including all registered and retained
unregistered checkouts. Removing or renaming a registry entry is not a file
migration or deletion operation.

## Migration from a single repository

The legacy `repository = { ... };` input remains accepted, but cannot be
combined with `repositories`. It is immediately normalized into the same
collection used by all runtime paths. Its key and checkout name retain the old
URL-basename (without `.git`) or explicit `checkoutName` behavior.

To migrate, replace `repository` with `repositories.<key>`. Choose the existing
checkout directory as the key, or preserve it explicitly with `checkoutName`.
Set `repositoryOnly = true` on any repository credential binding. Keep the
Workspace name and storage image names unchanged: neither the VM identity nor
its existing volumes need replacement. Add `defaultRepository` before adding
other repositories if you want existing `shell` / `run` commands to keep
selecting that checkout.

The generated lifecycle registry is version 7 and proxy policy is version 4;
the Runner identity remains version 3. Deploy CLI and host configuration
together through the normal NixOS generation, rather than editing generated
JSON. Legacy input compatibility does not imply compatibility with older
generated registry versions.

## Validation

Rust tests cover collection validation, explicit/default/sole selection and
CLI argument boundaries. Nix checks cover normalization, duplicate paths,
invalid defaults and bindings, and generated registry data. Proxy tests cover
two repositories on one host, multiple hosts, shared credentials, cross-path
denial and revocation. The native KVM lifecycle test covers two authenticated
checkouts, non-destructive partial failure/retry, selected entry, independent
direnv approvals, and preservation through restart and reset. This does not
extend the existing physical macOS validation claims.
