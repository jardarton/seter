{
  inputs,
  self,
  pkgs,
  system,
}:
let
  lib = pkgs.lib;
  base = {
    repositories = {
      frontend.url = "https://git.example/team/frontend.git";
      backend = {
        url = "https://second.example/team/backend.git";
        checkoutName = "api";
        credential = "gitToken";
      };
    };
    defaultRepository = "frontend";
    secrets.gitToken = {
      repositoryOnly = true;
      placeholder = "seter-placeholder-backend-0123456789abcdef";
      sourceFile = "/run/secrets/synthetic-git-token";
      hosts = [ "second.example" ];
      headers = [ "authorization" ];
    };
    network = {
      address = "10.100.0.10";
      mac = "02:00:00:00:00:10";
      tap = "seter-product";
    };
  };
  host =
    workspace:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.host
        {
          seter.host = {
            enable = true;
            workspaces.product = workspace;
          };
          system.stateVersion = "24.11";
          fileSystems."/" = {
            device = "/dev/vda";
            fsType = "ext4";
          };
          boot.loader.grub.devices = [ "nodev" ];
        }
      ];
    }).config;
  config = host base;
  repositoryLib = import ../nix/lib/repositories.nix { inherit lib; };
  legacy = {
    repository = {
      url = "https://git.example/team/original.git";
      checkoutName = "retained";
      branch = null;
      credential = null;
    };
    repositories = { };
  };
  rejected = workspace: lib.any (assertion: !assertion.assertion) (host workspace).assertions;
  python = pkgs.python3.withPackages (ps: [
    (ps.mitmproxy.overridePythonAttrs (old: {
      pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "msgpack" ];
    }))
  ]);
in
assert (repositoryLib.resolve legacy).retained.checkoutName == "retained";
assert
  builtins.attrNames (
    repositoryLib.resolve (
      legacy
      // {
        repository = legacy.repository // {
          checkoutName = null;
        };
      }
    )
  ) == [ "original" ];
assert
  repositoryLib.resolve legacy == repositoryLib.resolve {
    repository = null;
    repositories.retained = legacy.repository;
  };
assert lib.all (assertion: assertion.assertion) config.assertions;
assert rejected (
  base
  // {
    repositories = { };
    defaultRepository = null;
  }
);
assert rejected (base // { defaultRepository = "missing"; });
assert rejected (base // { repository.url = "https://git.example/team/legacy.git"; });
assert rejected (
  base
  // {
    repositories = base.repositories // {
      frontend = base.repositories.frontend // {
        checkoutName = "api";
      };
    };
  }
);
assert rejected (
  base
  // {
    repositories = base.repositories // {
      "../escape".url = "https://git.example/team/escape.git";
    };
  }
);
assert rejected (
  base
  // {
    repositories = base.repositories // {
      backend = base.repositories.backend // {
        credential = "missing";
      };
    };
  }
);
assert rejected (
  base
  // {
    secrets.gitToken = base.secrets.gitToken // {
      repositoryOnly = false;
    };
  }
);
pkgs.runCommand "seter-multi-repository-check"
  {
    nativeBuildInputs = [
      pkgs.jq
      python
      self.packages.${system}.seter
    ];
  }
  ''
    export SETER_REGISTRY=${config.environment.etc."seter/workspaces.json".source}
    jq -e '.version == 7 and .workspaces.product.defaultRepository == "frontend" and
      (.workspaces.product.repositories | keys == ["backend", "frontend"]) and
      .workspaces.product.repositories.frontend.checkoutName == "frontend" and
      .workspaces.product.repositories.backend.checkoutName == "api"' "$SETER_REGISTRY"
    test "$(seter list)" = product
    jq -e '.version == 4 and
      (.workspaces["10.100.0.10"].httpHosts | sort == ["git.example", "second.example"]) and
      (.workspaces["10.100.0.10"].repositories | keys == ["backend", "frontend"]) and
      .workspaces["10.100.0.10"].repositories.backend == {
        host: "second.example", path: "/team/backend.git", credential: "gitToken"
      } and .workspaces["10.100.0.10"].secrets.gitToken.repositoryOnly' \
      ${builtins.head config.systemd.services.seter-proxy.restartTriggers}
    jq -e '.allowedNames | sort == ["git.example", "second.example"]' \
      ${builtins.head config.systemd.services.seter-dns-product.restartTriggers}
    ${python}/bin/python ${./multi-repository-policy.py} ${../nix/modules/host/proxy-addon.py}
    touch "$out"
  ''
