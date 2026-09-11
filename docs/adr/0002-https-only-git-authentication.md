# HTTPS-only Git authentication

Seter's initial managed Git workflow supports HTTPS, not SSH, and injects a repository-scoped read/write credential at the host HTTP policy boundary. This preserves normal clone, fetch, and push workflows without placing a repository credential or host SSH agent in the guest; injection must be restricted to the approved repository's Git HTTP paths as well as its host, while branch protection and credential scope remain enforced by the Git service.

For named repository collections, the scope is the union of explicitly
associated repository host/path pairs, never the whole Git host. Repository-only
bindings remain denied after their last association is removed. Repositories
inside one Workspace share authority; see [ADR 0011](./0011-workspaces-contain-repository-collections.md).
