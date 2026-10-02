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
  localConfig = host (
    base
    // {
      repositories.local.local = true;
      defaultRepository = "local";
      secrets = { };
    }
  );
  repositoryHelpers = import ../nix/lib/repositories.nix { inherit lib; };
  rejected = workspace: lib.any (assertion: !assertion.assertion) (host workspace).assertions;
  python = pkgs.python3.withPackages (ps: [
    (ps.mitmproxy.overridePythonAttrs (old: {
      pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "msgpack" ];
    }))
  ]);
  policyPython = import ../nix/lib/policy-python.nix { inherit pkgs; };
in
assert lib.all (assertion: assertion.assertion) config.assertions;
assert lib.all (assertion: assertion.assertion) localConfig.assertions;
assert repositoryHelpers.hosts localConfig.seter.host.workspaces.product == [ ];
assert repositoryHelpers.remote localConfig.seter.host.workspaces.product == { };
assert rejected (
  base
  // {
    repositories.local = {
      local = true;
      url = "https://git.example/team/local.git";
    };
    defaultRepository = "local";
    secrets = { };
  }
);
assert rejected (
  base
  // {
    repositories.local = {
      local = true;
      credential = "gitToken";
    };
    defaultRepository = "local";
  }
);
assert rejected (
  base
  // {
    repositories.local = { };
    defaultRepository = "local";
  }
);
assert rejected (
  base
  // {
    repositories = { };
    defaultRepository = null;
  }
);
assert rejected (base // { defaultRepository = "missing"; });
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
    jq -e '.version == 8 and .workspaces.product.defaultRepository == "frontend" and
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
    PYTHONPATH=${policyPython} ${python}/bin/python ${./multi-repository-policy.py} ${policyPython}/proxy-addon.py
    touch "$out"
  ''
