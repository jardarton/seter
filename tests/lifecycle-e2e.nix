{
  inputs,
  self,
  pkgs,
  system,
}:
let
  # RFC 9500 test key. Public test data; never use it for real access.
  testSshPrivateKey = pkgs.writeText "seter-e2e-ssh-key" ''
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIObLW92AqkWunJXowVR2Z5/+yVPBaFHnEedDk5WJxk/BoAoGCCqGSM49
    AwEHoUQDQgAEQiVI+I+3gv+17KN0RFLHKh5Vj71vc75eSOkyMsxFxbFsTNEMTLjV
    uKFxOelIgsiZJXKZNCX0FBmrfpCkKklCcg==
    -----END EC PRIVATE KEY-----
  '';
  testSshPublicKey =
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHA"
    + "yNTYAAABBBEIlSPiPt4L/teyjdERSxyoeVY+9b3O+XkjpMjLMRcWxbEzRDEy41b"
    + "ihcTnpSILImSVymTQl9BQZq36QpCpJQnI= seter-e2e";

  seterPackage = self.packages.${system}.seter;
  unrelatedStoreSentinel = pkgs.writeText "seter-unrelated-host-store-sentinel" "host confidential sentinel\n";
  bootstrapMitmCaCertificate = ./fixtures/bootstrap-mitm-ca-cert.pem;
  bootstrapMitmCaPrivateKey = ./fixtures/bootstrap-mitm-ca-key.pem;
  bootstrapGitServerCertificate = ./fixtures/bootstrap-git-server-cert.pem;
  bootstrapGitServerPrivateKey = ./fixtures/bootstrap-git-server-key.pem;
  repositoryToken = "seter-bootstrap-test-token-0123456789";

  gitHttpServer = pkgs.writeText "seter-bootstrap-git-http-server.py" ''
    import os
    import ssl
    import subprocess
    import sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    token, certificate, private_key = sys.argv[1:4]

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.serve_git()

        def do_POST(self):
            self.serve_git()

        def serve_git(self):
            authorization = self.headers.get("Authorization", "")
            if authorization != f"Bearer {token}":
                body = b"repository authentication required\n"
                self.send_response(401)
                self.send_header("WWW-Authenticate", "Bearer")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            with open("/tmp/git-authorized-requests", "a", encoding="utf-8") as log:
                log.write(f"{self.command} {self.path}\n")

            path, _, query = self.path.partition("?")
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            environment = os.environ.copy()
            environment.update({
                "GIT_PROJECT_ROOT": "/srv/git",
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": path,
                "QUERY_STRING": query,
                "REQUEST_METHOD": self.command,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(length),
                "REMOTE_USER": "seter",
            })
            result = subprocess.run(
                ["${pkgs.git}/libexec/git-core/git-http-backend"],
                input=body,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            header_block, separator, response_body = result.stdout.partition(b"\r\n\r\n")
            if not separator:
                response_body = result.stderr or b"invalid git backend response\n"
                self.send_response(500)
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
                return
            status = 200
            headers = []
            for line in header_block.decode("latin-1").split("\r\n"):
                key, value = line.split(":", 1)
                if key.lower() == "status":
                    status = int(value.strip().split()[0])
                else:
                    headers.append((key, value.strip()))
            self.send_response(status)
            for key, value in headers:
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

        def log_message(self, format, *args):
            pass

    server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, private_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
  '';

  workspace = {
    repository = {
      url = "https://git.fixture/owner/e2e.git";
      credential = "repositoryToken";
    };
    network = {
      address = "10.100.0.20";
      mac = "02:00:00:00:00:20";
      tap = "seter-e2e";
    };
    resources = {
      memoryMiB = 1024;
      cpuQuotaPercent = 200;
    };
    ssh.authorizedKeys = [ testSshPublicKey ];
    storage = {
      project.sizeMiB = 512;
      home.sizeMiB = 512;
      nixStore.sizeMiB = 1024;
    };
    secrets.repositoryToken = {
      placeholder = "seter-placeholder-repository-0123456789abcdef";
      sourceFile = "/run/secrets/seter-repository-token";
      hosts = [ "git.fixture" ];
      headers = [ "authorization" ];
    };
  };

  deployment = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.host
      {
        seter.host = {
          enable = true;
          package = seterPackage;
          proxyCaCertificate = builtins.readFile bootstrapMitmCaCertificate;
          workspaces.e2e = workspace;
        };
        system.stateVersion = "24.11";
      }
    ];
  };
  runner = deployment.config.environment.etc."seter/runners/e2e".source;
  normalDevelopmentFlake = pkgs.runCommand "seter-normal-development-flake" { } ''
    mkdir -p "$out"
    cat > "$out/flake.nix" <<'EOF'
    {
      description = "Ordinary development flake used by the Seter default-profile test";

      outputs = { self }:
        let
          # The KVM test fills these with package paths from the booted
          # Runner. Opaque contexts model already-realized flake dependencies
          # without requiring public network access in this default-deny test.
          bash = builtins.appendContext "@bash@" {
            "@bash@" = { path = true; };
          };
          coreutils = builtins.appendContext "@coreutils@" {
            "@coreutils@" = { path = true; };
          };
        in {
          devShells.${system}.default = derivation {
            name = "seter-normal-development-shell";
            outputs = [ "out" ];
            system = "${system}";
            builder = "''${bash}/bin/bash";
            args = [ "-c" "mkdir -p \"$out\"" ];
            PATH = "''${coreutils}/bin";
            shellHook = "export NORMAL_DEVELOPMENT_FLAKE=ready";
          };
        };
    }
    EOF
    printf '%s\n' 'use flake' > "$out/.envrc"
  '';
in
pkgs.testers.runNixOSTest {
  name = "seter-lifecycle-e2e";

  nodes = {
    gitserver = {
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "11.0.0.2";
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedTCPPorts = [ 443 ];
      users.groups.gitfixture = { };
      users.users.gitfixture = {
        isSystemUser = true;
        group = "gitfixture";
      };
      systemd.tmpfiles.rules = [ "d /srv/git 0750 gitfixture gitfixture -" ];
      systemd.services.git-fixture = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          User = "gitfixture";
          Group = "gitfixture";
          StateDirectory = "seter-git-fixture";
          ExecStartPre = pkgs.writeShellScript "initialize-seter-git-fixture" ''
            set -eu
            if ! test -d /srv/git/owner/e2e.git; then
              install -d -o gitfixture -g gitfixture /srv/git/owner
              ${pkgs.git}/bin/git init --bare --initial-branch=main /srv/git/owner/e2e.git
              ${pkgs.git}/bin/git -C /srv/git/owner/e2e.git config http.receivepack true
              work=$(mktemp -d)
              ${pkgs.git}/bin/git -C "$work" init --initial-branch=main
              ${pkgs.git}/bin/git -C "$work" config user.name 'Seter Bootstrap Test'
              ${pkgs.git}/bin/git -C "$work" config user.email seter@example.invalid
              cp -r ${normalDevelopmentFlake}/. "$work"/
              chmod -R u+w "$work"
              printf '%s\n' bootstrap-ready > "$work/README.md"
              ${pkgs.git}/bin/git -C "$work" add .
              ${pkgs.git}/bin/git -C "$work" commit -m initial
              ${pkgs.git}/bin/git -C "$work" remote add origin /srv/git/owner/e2e.git
              ${pkgs.git}/bin/git -C "$work" push origin main
              rm -rf "$work"
              chown -R gitfixture:gitfixture /srv/git
            fi
          '';
          ExecStart = "${pkgs.python3}/bin/python ${gitHttpServer} ${repositoryToken} ${bootstrapGitServerCertificate} ${bootstrapGitServerPrivateKey}";
          AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
          Restart = "on-failure";
        };
      };
      system.stateVersion = "24.11";
    };

    machine =
      { lib, ... }:
      {
        imports = [ self.nixosModules.host ];

        environment.systemPackages = [
          seterPackage
          pkgs.jq
          pkgs.openssh
        ];

        users.users.operator = {
          isNormalUser = true;
          extraGroups = [ "seter-operators" ];
        };

        seter.host = {
          enable = true;
          package = seterPackage;
          proxyCaCertificate = builtins.readFile bootstrapMitmCaCertificate;
          proxy.upstreamCaFile = bootstrapMitmCaCertificate;
          workspaces.e2e = workspace;
        };

        networking.hosts."11.0.0.2" = [ "git.fixture" ];
        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "11.0.0.1";
            prefixLength = 24;
          }
        ];

        systemd.tmpfiles.rules = [
          "d /run/secrets 0700 root root -"
          "f /run/secrets/seter-repository-token 0400 root root - Bearer\\x20${repositoryToken}"
        ];

        system.activationScripts.seterBootstrapTestCa = lib.stringAfter [ "users" ] ''
          install -d -m 0700 -o seter-proxy -g seter-proxy /var/lib/seter-proxy
          cat ${bootstrapMitmCaPrivateKey} ${bootstrapMitmCaCertificate} > /var/lib/seter-proxy/mitmproxy-ca.pem
          install -m 0600 -o seter-proxy -g seter-proxy ${bootstrapMitmCaCertificate} /var/lib/seter-proxy/mitmproxy-ca-cert.pem
          ${pkgs.openssl}/bin/openssl pkcs12 -export -passout pass: \
            -inkey ${bootstrapMitmCaPrivateKey} -in ${bootstrapMitmCaCertificate} \
            -out /var/lib/seter-proxy/mitmproxy-ca.p12
          chown seter-proxy:seter-proxy /var/lib/seter-proxy/mitmproxy-ca.pem /var/lib/seter-proxy/mitmproxy-ca.p12
          chmod 0600 /var/lib/seter-proxy/mitmproxy-ca.pem /var/lib/seter-proxy/mitmproxy-ca.p12
        '';

        virtualisation = {
          memorySize = 4096;
          cores = 2;
          additionalPaths = [
            runner
            normalDevelopmentFlake
            unrelatedStoreSentinel
          ];
          qemu = {
            forceAccel = lib.mkForce true;
            options = [ "-cpu host" ];
          };
        };

        system.stateVersion = "24.11";
      };
  };

  testScript = ''
    start_all()

    machine.wait_for_unit("seter-bridge.service")
    machine.wait_for_unit("seter-proxy.service")
    gitserver.wait_for_unit("git-fixture.service")
    machine.succeed("test -e /dev/kvm")

    # Host deployment creates and protects the Workspace SSH Identity before
    # the first guest boot. Operators can read only its public half.
    machine.succeed("test $(stat -c %U:%G /var/lib/seter/identities/e2e/ssh_host_ed25519_key) = root:root")
    machine.succeed("test $(stat -c %a /var/lib/seter/identities/e2e/ssh_host_ed25519_key) = 600")
    machine.succeed("su - operator -c 'seter ssh-host-key e2e' > /tmp/e2e-host-key 2>/tmp/e2e-fingerprint")
    machine.succeed("cmp /tmp/e2e-host-key /var/lib/seter/identities/e2e/ssh_host_ed25519_key.pub; grep -F SHA256: /tmp/e2e-fingerprint")
    machine.succeed("sha256sum /var/lib/seter/identities/e2e/ssh_host_ed25519_key > /tmp/identity-hash")

    # The registry, lifecycle units, and immutable Runner are one NixOS
    # generation. No project installable or mutable current-runner link exists.
    machine.succeed("test $(readlink -f /etc/seter/runners/e2e) = ${runner}")
    machine.succeed("jq -e '.version == 5 and .workspaces.e2e.guestProfile == \"default\" and .workspaces.e2e.repository.url == \"https://git.fixture/owner/e2e.git\" and .workspaces.e2e.repository.credential.placeholder == \"seter-placeholder-repository-0123456789abcdef\" and .workspaces.e2e.runner.path == \"${runner}\"' /etc/seter/workspaces.json")
    machine.fail("test -e /var/lib/seter/workspaces/e2e/current")
    machine.fail("su - operator -c 'seter update e2e'")

    machine.succeed("install -m 0600 ${testSshPrivateKey} /tmp/seter-e2e-key")
    machine.succeed("install -d -o operator -g users -m 0700 /home/operator/.ssh; install -o operator -g users -m 0600 ${testSshPrivateKey} /home/operator/.ssh/id_ecdsa")
    machine.succeed("su - operator -c 'seter init e2e' | grep -F 'Initialized repository at /project/e2e'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds("ssh-keyscan -T 2 10.100.0.20 > /tmp/e2e-known-hosts 2>/dev/null && test -s /tmp/e2e-known-hosts", timeout=360)

    machine.succeed("key=$(awk '{print $2}' /tmp/e2e-host-key); grep -F \" $key\" /tmp/e2e-known-hosts")
    ssh_options = "-i /tmp/seter-e2e-key -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/e2e-known-hosts -o GlobalKnownHostsFile=/dev/null"
    machine.succeed(f"timeout 60s ssh {ssh_options} seter@10.100.0.20 -- 'cd /project/e2e && test $(git remote get-url origin) = https://git.fixture/owner/e2e.git && test $(git branch --show-current) = main && grep -Fx bootstrap-ready README.md && if direnv exec . true; then exit 1; fi && printf sentinel > bootstrap-sentinel'")
    gitserver.succeed("grep -F 'GET /owner/e2e.git/info/refs?service=git-upload-pack' /tmp/git-authorized-requests")
    machine.succeed("su - operator -c 'seter init e2e' | grep -F 'already initialized'")
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'test $(cat /project/e2e/bootstrap-sentinel) = sentinel'")

    # The non-secret placeholder can be observed in the guest, but the real
    # credential cannot. Even a manually constructed request cannot use it on
    # a sibling repository path.
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- '! grep -R -F ${repositoryToken} /project /home 2>/dev/null && test $(curl --silent --output /tmp/unauthorized-body --write-out %{{http_code}} -H \"Authorization: Bearer seter-placeholder-repository-0123456789abcdef\" https://git.fixture/owner/other.git/info/refs?service=git-upload-pack) = 403 && grep -F \"not bound to path\" /tmp/unauthorized-body && test $(curl --path-as-is --silent --output /tmp/traversal-body --write-out %{{http_code}} -H \"Authorization: Bearer seter-placeholder-repository-0123456789abcdef\" https://git.fixture/owner/e2e.git/../other.git/info/refs?service=git-upload-pack) = 403 && grep -F \"not bound to path\" /tmp/traversal-body'")

    # A complete checkout is never reset or overwritten, and a mismatched
    # remote receives a direct explanation without changing working data.
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'git -C /project/e2e remote set-url origin https://git.fixture/owner/other.git'")
    machine.succeed("set +e; su - operator -c 'seter init e2e' > /tmp/mismatch 2>&1; code=$?; set -e; test $code = 20; grep -F 'has origin https://git.fixture/owner/other.git, expected https://git.fixture/owner/e2e.git' /tmp/mismatch")
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'test $(cat /project/e2e/bootstrap-sentinel) = sentinel; git -C /project/e2e remote set-url origin https://git.fixture/owner/e2e.git; git -C /project/e2e config user.name Seter; git -C /project/e2e config user.email seter@example.invalid; printf pushed > /project/e2e/pushed; git -C /project/e2e add pushed; git -C /project/e2e commit -m pushed; git -C /project/e2e push origin main'")
    gitserver.succeed("${pkgs.git}/bin/git --git-dir=/srv/git/owner/e2e.git show main:pushed | grep -Fx pushed")

    # A clone interrupted after its Git metadata and approved origin exist can
    # be recovered only while it has no working data. Preserve the complete
    # checkout out of band so the test can also prove recovery did not touch it.
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'mv /project/e2e /project/e2e-complete; git init /project/e2e; git -C /project/e2e remote add origin https://git.fixture/owner/e2e.git'")
    machine.succeed("su - operator -c 'seter init e2e' | grep -F 'Recovered and initialized repository at /project/e2e'")
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'test $(git -C /project/e2e branch --show-current) = main && test $(cat /project/e2e/pushed) = pushed && test $(cat /project/e2e-complete/bootstrap-sentinel) = sentinel'")

    # Git establishes HEAD before checkout, so an interruption can leave a
    # resolvable commit but no working files. Seter's marker makes that state
    # recoverable without treating arbitrary user deletions as bootstrap data.
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'mv /project/e2e /project/e2e-before-head-recovery; mkdir /project/e2e; cp -a /project/e2e-before-head-recovery/.git /project/e2e/.git; mkdir /project/.seter-bootstrap-e2e'")
    machine.succeed("su - operator -c 'seter init e2e' | grep -F 'Recovered and initialized repository at /project/e2e'")
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'test $(cat /project/e2e/pushed) = pushed && test ! -e /project/.seter-bootstrap-e2e'")

    # A linked Git directory is unrelated content, even when the linked
    # repository happens to have the approved origin.
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'mv /project/e2e /project/e2e-before-symlink-check; mkdir /project/e2e; ln -s /project/e2e-before-symlink-check/.git /project/e2e/.git'")
    machine.succeed("set +e; su - operator -c 'seter init e2e' > /tmp/git-symlink 2>&1; code=$?; set -e; test $code = 20; grep -F 'symbolic-link .git directory' /tmp/git-symlink")
    machine.succeed(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'rm /project/e2e/.git; rmdir /project/e2e; mv /project/e2e-before-symlink-check /project/e2e'")

    machine.succeed(f"timeout 60s ssh {ssh_options} seter@10.100.0.20 -- 'test -e /etc/vm-guest && command -v git && command -v curl && command -v diff && command -v file && command -v find && command -v grep && command -v less && command -v sed && command -v ssh && command -v tar && command -v xz && command -v direnv && test -e /etc/direnv/direnvrc && grep -F nix-direnv /etc/direnv/direnvrc && bash -lic \"type _direnv_hook >/dev/null\" && test -s /etc/ssl/certs/ca-bundle.crt && nix config show experimental-features | grep -F nix-command | grep -F flakes && test $(findmnt -n -o FSTYPE /nix/store | sort -u) = overlay && test $(cat /nix/var/nix/seter-store-view) = $(readlink -f /run/booted-system) && test $(readlink -f /nix/var/nix/gcroots/seter-lower-closures/current) = $(readlink -f /run/booted-system) && test ! -e ${unrelatedStoreSentinel} && ! test -r /run/seter-identity/ssh_host_ed25519_key && printf project-persistent > /project/runner-model-marker && printf home-persistent > ~/.seter-home-marker && printf nix-persistent > /tmp/nix-marker && nix-store --add-fixed sha256 /tmp/nix-marker > /project/nix-marker-path'")
    machine.succeed("grep -Fx 'host confidential sentinel' ${unrelatedStoreSentinel}")

    # A repository needs only its normal flake and .envrc. Copying this local
    # fixture models the post-bootstrap working tree without introducing any
    # repository-owned NixOS or Seter configuration. Merely entering it does
    # not approve the .envrc; activation succeeds only after an explicit allow.
    machine.succeed(f"timeout 60s ssh {ssh_options} seter@10.100.0.20 -- 'mkdir /project/normal-development-flake'")
    machine.succeed(f"timeout 60s scp {ssh_options} -r ${normalDevelopmentFlake}/. seter@10.100.0.20:/project/normal-development-flake/")
    machine.succeed(f"timeout 120s ssh {ssh_options} seter@10.100.0.20 -- 'cd /project/normal-development-flake; bash_store=$(dirname $(dirname $(readlink -f $(command -v bash)))); coreutils_store=$(dirname $(dirname $(readlink -f $(command -v mkdir)))); sed -i \"s|@bash@|$bash_store|g; s|@coreutils@|$coreutils_store|g\" flake.nix; if direnv exec . true; then exit 1; fi; direnv allow .; export NIX_CONFIG=\"substituters =\"; direnv exec . env | grep -Fx NORMAL_DEVELOPMENT_FLAKE=ready; nix develop path:. --command env | grep -Fx NORMAL_DEVELOPMENT_FLAKE=ready'")

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-vm-e2e.service")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-project.img")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-home.img")
    machine.succeed("test -s /var/lib/seter/workspaces/e2e/e2e-nix-store.img")
    machine.succeed("sha256sum -c /tmp/identity-hash")

    machine.succeed("su - operator -c 'seter up e2e' | grep -F 'Started e2e at 10.100.0.20'")
    machine.wait_for_unit("seter-vm-e2e.service")
    machine.wait_until_succeeds(f"timeout 30s ssh {ssh_options} seter@10.100.0.20 -- 'test $(cat /project/runner-model-marker) = project-persistent && test $(cat ~/.seter-home-marker) = home-persistent && test $(cat $(cat /project/nix-marker-path)) = nix-persistent && cd /project/normal-development-flake && direnv exec . env | grep -Fx NORMAL_DEVELOPMENT_FLAKE=ready && test ! -e ${unrelatedStoreSentinel}'", timeout=300)
    machine.succeed("printf 'test \"$(cat /project/runner-model-marker)\" = project-persistent && test \"$(cat ~/.seter-home-marker)\" = home-persistent && echo shell-ok\\nexit\\n' | su - operator -c \"timeout 30s script -qec 'seter shell e2e' /dev/null\" | grep -F shell-ok")

    machine.succeed("su - operator -c 'seter down e2e' | grep -F 'Stopped e2e'")
    machine.wait_until_fails("systemctl is-active --quiet seter-runtime-e2e.target")
    machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")
  '';
}
