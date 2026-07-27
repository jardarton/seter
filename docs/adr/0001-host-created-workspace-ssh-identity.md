# Host-created workspace SSH identity

Seter creates each workspace's SSH host key in root-owned host state before its first boot and supplies that identity to the guest. This keeps SSH verification strict while avoiding manual first-boot enrollment and trust-on-first-use; the host already controls the VM runtime and storage, so creating the guest's server identity does not expand the meaningful trust boundary.
