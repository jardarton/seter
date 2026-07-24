# Upstream Projects

Seter builds on established upstream projects rather than reimplementing their functionality. This list records the verified project locations and distinguishes direct flake inputs from software consumed through Nixpkgs.

## Direct flake inputs

| Project | Repository | Purpose |
|---|---|---|
| Nixpkgs / NixOS | [NixOS/nixpkgs](https://github.com/NixOS/nixpkgs) | NixOS module system, packages, VM tooling, networking tools, and build infrastructure |
| flake-parts | [hercules-ci/flake-parts](https://github.com/hercules-ci/flake-parts) | Organization of Seter's flake outputs |
| nix-systems default-linux | [nix-systems/default-linux](https://github.com/nix-systems/default-linux) | Supported Linux system definitions; an official Linux-specific specialization of `nix-systems/default` |
| microvm.nix | [microvm-nix/microvm.nix](https://github.com/microvm-nix/microvm.nix) | NixOS micro-VM definitions and runners |

The former `astro/microvm.nix` URL redirects after the project transfer. New references should use `microvm-nix/microvm.nix` directly.

## Runtime and integration projects

These are canonical project repositories, but Seter should generally consume their packaged versions through Nixpkgs rather than adding them as flake inputs.

| Project | Repository | Purpose |
|---|---|---|
| mitmproxy | [mitmproxy/mitmproxy](https://github.com/mitmproxy/mitmproxy) | HTTP/HTTPS policy enforcement, secret injection, and request auditing |
| Cloud Hypervisor | [cloud-hypervisor/cloud-hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) | Preferred initial virtual machine monitor |
| sops-nix | [Mic92/sops-nix](https://github.com/Mic92/sops-nix) | Optional consumer-provided host secret management |
| agenix | [ryantm/agenix](https://github.com/ryantm/agenix) | Alternative optional consumer-provided host secret management |
| nix-direnv | [nix-community/nix-direnv](https://github.com/nix-community/nix-direnv) | Cached flake development environment activation inside guests |
| Lima | [lima-vm/lima](https://github.com/lima-vm/lima) | Future outer Linux VM on supported macOS hosts |

Seter should not require either sops-nix or agenix directly. Its module interface should accept runtime secret-file paths supplied by the consumer's chosen secret manager.

## System components supplied by Nixpkgs

Seter also relies on the following system components, all installed and configured through Nixpkgs:

- nftables — default-deny egress enforcement and transparent proxy redirection
- dnsmasq — workspace hostname resolution
- systemd — transient VM units and resource limits
- OpenSSH — guest command execution and interactive shells
- iproute2 — bridge and tap interface management
- direnv — development environment activation

The GitHub repository [`google/nftables`](https://github.com/google/nftables) is the canonical repository for Google's Go nftables library, **not** the authoritative upstream source for the nftables system project used by Seter.

The GitHub repository [`imp/dnsmasq`](https://github.com/imp/dnsmasq) is an explicit mirror, not the authoritative dnsmasq upstream. Neither repository should be presented as a direct Seter dependency or authoritative upstream source.

## Excluded integrations

Tailscale is intentionally omitted from this dependency list for now.
