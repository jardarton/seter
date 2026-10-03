# Serve the host store as a workspace Nix cache

Partially supersedes [ADR 0008](./0008-filter-host-store-by-runner-closure.md).

Workspaces substitute from a read-only Harmonia binary cache that serves the whole host Nix store through Seter's gateway relay. The Runner still boots from its closure-filtered Store View, and project builds still run only in the workspace's private writable store.

Seter's store boundary protects two properties: project code never executes on the host, and a workspace cannot mutate or fill the host store. Harmonia preserves both because it serves only existing valid paths and has no build, evaluation, or upload interface. Confidentiality of store contents is not one of those properties. The Nix store is world-readable to every host account, and real secrets were already forbidden from it. Hiding unrelated paths from workspaces therefore cost a per-Runner image copy of every reused closure and host-side evaluation of approved development outputs, while protecting data that Nix does not treat as secret.

A workspace can now read any host store path, including another workspace's source snapshots. Harmonia's file-serving endpoint can also expose store directory listings, so Seter does not claim the host store is unlistable. A workspace still cannot write to the host store or build in it. The guest marks the cache as trusted instead of verifying signatures, because only the host can answer on the anti-spoofed gateway address, and Nix still verifies each NAR's hash. Exfiltration is limited by egress policy, not by store visibility. Consumers can disable the cache for the host or for individual workspaces.
