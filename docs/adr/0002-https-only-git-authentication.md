# HTTPS-only Git authentication

Seter's initial managed Git workflow supports HTTPS, not SSH, and injects a repository-scoped read/write credential at the host HTTP policy boundary. This preserves normal clone, fetch, and push workflows without placing a repository credential or host SSH agent in the guest; injection must be restricted to the approved repository's Git HTTP paths as well as its host, while branch protection and credential scope remain enforced by the Git service.
