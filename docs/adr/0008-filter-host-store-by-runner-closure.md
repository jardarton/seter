# Filter the shared host store by Runner closure

A workspace's read-only Store View contains only paths reachable from its deployed and retained Runner closures, rather than the host's entire `/nix/store`. A filtered view requires additional host mount-namespace and lifecycle machinery, but preserves shared boot-path deduplication without exposing unrelated project sources and host configuration artifacts; paths built or substituted by project code remain in the workspace's private writable store.
