# Deploy default-profile runners with the host

Default-profile runners are built, installed, and rooted as part of trusted NixOS host deployment rather than built from project repositories by `seter update`. Because project code now enters only through Workspace Bootstrap and executes inside the guest, keeping a separate runner-update lifecycle would preserve stale-identity and authorization complexity without a trust benefit; host deployment may take longer, but successful deployment atomically aligns each Runner with its Workspace Registry identity and Guest Profile.
