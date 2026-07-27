# Trusted Guest Profile as the default

Seter's first usable workflow builds ordinary workspaces entirely from a trusted `default` Guest Profile, so repositories need only their normal development flake and cannot alter guest operating-system configuration. Specialized guest configuration is deferred: arbitrary repository-owned NixOS modules cannot honestly be constrained to “extension only,” so a future decision must choose between restricted capability requests, trusted custom profiles, and an explicitly untrusted advanced runner path.
