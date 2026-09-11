# Candidate design directions

These are possible follow-ups, not implemented features or roadmap commitments.
Each needs demonstrated workflow demand, a threat-model review, and a bounded
prototype before adoption.

| Candidate | Useful direction | Required boundary or unresolved cost |
|---|---|---|
| Per-Workspace proxy | Isolate credential access, invalid-credential failures, and rotation to one Workspace instead of the shared proxy. | Benchmark one Python process per active Workspace; preserve source binding and existing enforcement. |
| Capability broker | Expose narrow Host operations through workspace-bound endpoints, potentially using vsock and systemd activation. | Derive identity from the assigned endpoint, not a guest field; never expose a general shell or raw privileged daemon. |
| Upstream mTLS | Reuse mitmproxy client certificates for exact-destination authority without guest private keys. | Keep keys Host-side; prefer per-Workspace proxy isolation before adding more shared credentials. |
| AWS request signing | Evaluate [aws-sigv4-proxy](https://github.com/awslabs/aws-sigv4-proxy). | Fix destination, service, region, and least-privilege role; do not expose arbitrary upstream selection. |
| Dev Container Guest Profile | Evaluate [Envbuilder](https://github.com/coder/envbuilder) rather than implementing the ecosystem anew. | VM remains the security boundary; repository configuration requires explicit approval; Nix-native default stays available. |
| Dynamic credentials | Consume short-lived credentials from existing secret managers and workload-identity tools. | Seter binds authority; it should not become a secret manager or run arbitrary credential-provider commands as root. See [repository credential work](../TODO.md). |
| Disposable Workspaces | Explore copy-on-write state for one-off tasks. | First define how dirty Project data enters and leaves; never make working-tree deletion implicit. |
| Prebuilt environments | Reduce repeated dependency realization if measured usage warrants it. | Execute repository code only inside the Workspace, never during trusted Host deployment. |

Reuse maintained components only where they remove complexity. Terraform/Salt,
Kubernetes/Cilium, another policy language, or an immediate proxy-engine rewrite
would duplicate current machinery without a demonstrated requirement. Extra
same-kernel sandboxes do not replace the VM boundary. Generic SSH-agent
forwarding into Workspaces grants signing authority and is not a substitute
for repository-bound credentials or operation-specific brokers.

Start with the shared proxy's failure domain and one concrete capability use
case. Other integrations should follow real demand rather than expanding the
public interface speculatively.
