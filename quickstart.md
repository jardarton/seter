# Seter quickstart

This guide adds Seter to a flake-based NixOS host and starts one workspace. Seter currently requires a Linux host with Nix flakes and working KVM (`/dev/kvm`).

## 1. Add Seter to the host flake

Add the Seter input and host module to your NixOS flake. Adapt the existing `nixosConfigurations` rather than copying this whole example if your flake is already structured differently.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    seter = {
      url = "github:jardarton/seter";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, seter, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        seter.nixosModules.host
        ./configuration.nix
      ];
    };
  };
}
```

## 2. Register a workspace

Add a workspace to trusted NixOS configuration. This first example assumes a public HTTPS repository; private repositories need a [repository credential binding](./README.md#workspace-bootstrap).

Replace the user name, repository, public SSH key, and network identity below. Each workspace needs a unique address, MAC address, and TAP name. If necessary, create a login key with `ssh-keygen -t ed25519` and copy the contents of its `.pub` file into `ssh.authorizedKeys`.

```nix
{ ... }:
{
  seter.host = {
    enable = true;

    workspaces.project = {
      repository.url = "https://github.com/owner/project.git";

      network = {
        address = "10.100.0.10";
        mac = "02:00:00:00:00:10";
        tap = "seter-project";
      };

      ssh.authorizedKeys = [
        "ssh-ed25519 AAAA... alice@my-host"
      ];

      # Permit the initial clone without TLS interception. Replace this with
      # your repository host when it is not github.com.
      egress.passthroughHosts = [ "github.com" ];
    };
  };

  users.users.alice.extraGroups = [ "seter-operators" ];
}
```

The defaults allocate 4 GiB each for the Project and Home Volumes, 16 GiB for the private Nix store, 4 GiB of guest RAM, and a 200% CPU quota. See the [Workspace Registry](./README.md#workspace-registry) for common overrides.

## 3. Deploy the host

Deploy through your normal trusted NixOS workflow. For a local flake deployment, that is commonly:

```console
sudo nixos-rebuild switch --flake .#my-host
```

Log out and back in after the first deployment so membership in `seter-operators` takes effect. Confirm that the workspace is registered:

```console
seter status project
```

A newly deployed workspace should report `stopped`.

## 4. Bootstrap and enter the workspace

Bootstrap clones the approved repository into its persistent Project Volume:

```console
seter init project
seter shell project
```

The shell opens in the registered checkout. If the repository has an `.envrc`, review it before approving it:

```console
direnv allow
exit
```

Seter does not approve repository code automatically. The workspace remains running after you leave the shell.

Run a command non-interactively or stop the workspace with:

```console
seter run project -- cargo test
seter down project
```

`seter run` uses `direnv`; it fails closed until the checkout's `.envrc` has been approved.

## 5. Add only the network access the project needs

The example grants passthrough HTTPS only to the repository host. Development commands may reveal additional blocked destinations. Inspect observations with:

```console
seter audit project --since 30m
```

Review each destination, add narrow `egress.httpHosts`, `egress.passthroughHosts`, or `egress.tcp` grants to trusted configuration, and redeploy the host. For a reviewable TOML-based workflow, see [Policy observation and review](./docs/policy-workflow.md).

For intercepted HTTPS, first export the public Seter proxy CA, verify its fingerprint through a trusted channel, commit only the public certificate to trusted host configuration, and redeploy:

```console
seter proxy-ca > seter-proxy-ca-cert.pem
```

```nix
seter.host.proxyCaCertificate =
  builtins.readFile ./seter-proxy-ca-cert.pem;
```

Never copy `/var/lib/seter-proxy/mitmproxy-ca.pem`; it contains the private signing key. See [Network isolation](./README.md#network-isolation) for proxy trust, TLS passthrough, direct TCP, host services, and secret injection.
