# Workspaces contain named repository collections

A Workspace is one isolation and policy boundary containing one or more
approved repositories. Repository identity, source, initial branch, checkout
directory and credential association belong to a named collection. VM identity,
Guest Profile, resources, storage and grants remain Workspace-wide. This
supports related multi-repository development without a second VM mode or a
fictional per-repository security boundary inside one guest.

Bootstrap is independently retryable per repository, never a transaction that
rolls back working data. Entry selects a repository explicitly or through a
declared default; ambiguous selection fails. The Project Volume holds all
checkouts and is never split or deleted merely because the registry changes.

Credential injection is authorized against the union of explicitly associated
exact repository host/path pairs. Named repositories require repository-only
bindings, so revoking the final association cannot broaden a credential into
generic host-wide authority. Credentials remain outside the guest, but all
code in the Workspace can exercise the Workspace's combined authority.

The legacy singular configuration is normalized at the Nix input boundary;
there is only one runtime model. See [the workflow and migration guide](../multi-repository-workspaces.md).
