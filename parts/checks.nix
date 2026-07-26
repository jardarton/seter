{ inputs, self, ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      mkWorkspace =
        {
          ip,
          mac,
          tap,
          knownHostKey ? null,
        }:
        self.lib.mkWorkspace {
          runnerInstallable = "github:example/project#nixosConfigurations.guest.config.microvm.declaredRunner";
          inherit
            ip
            knownHostKey
            mac
            tap
            ;
        };

      hostModuleBase = {
        seter.host.enable = true;
        system.stateVersion = "24.11";
        fileSystems."/" = {
          device = "/dev/vda";
          fsType = "ext4";
        };
        boot.loader.grub.devices = [ "nodev" ];
      };

      mkHostWith =
        host:
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.host
            hostModuleBase
            { seter.host = host; }
          ];
        };

      mkHost = workspaces: mkHostWith { inherit workspaces; };

      validWorkspaces = {
        alpha = mkWorkspace {
          ip = "10.100.0.10";
          mac = "02:00:00:00:00:10";
          tap = "seter-alpha";
          knownHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey alpha-test";
        };
        beta = mkWorkspace {
          ip = "10.100.0.11";
          mac = "02:00:00:00:00:11";
          tap = "seter-beta";
        };
      };

      dnsPortsFor = workspaces: import ../nix/modules/host/dns-ports.nix { inherit lib workspaces; };
      workspaceDnsPorts = dnsPortsFor validWorkspaces;
      alphaDnsPort = workspaceDnsPorts.alpha;
      betaDnsPort = workspaceDnsPorts.beta;
      alphaDnsPortWithEarlierWorkspace = (dnsPortsFor ({ aardvark = { }; } // validWorkspaces)).alpha;

      tcpTestWorkspaces = validWorkspaces // {
        alpha = validWorkspaces.alpha // {
          egress.tcp = [
            {
              host = "direct.example";
              port = 2222;
            }
          ];
        };
      };
      tcpSetsFor = workspaces: import ../nix/modules/host/tcp-egress-sets.nix { inherit lib workspaces; };
      alphaTcpSet = (tcpSetsFor tcpTestWorkspaces).alpha;
      tcpHostConfiguration = mkHost tcpTestWorkspaces;

      gatewayServiceWorkspaces = validWorkspaces // {
        alpha = validWorkspaces.alpha // {
          hostServices = [ "adb" ];
        };
      };
      gatewayServiceConfiguration = mkHostWith {
        workspaces = gatewayServiceWorkspaces;
        gatewayServices.adb = {
          listenPort = 5037;
          targetPort = 15037;
        };
      };
      gatewayServiceSocket = gatewayServiceConfiguration.config.systemd.sockets.seter-gateway-adb;
      gatewayService = gatewayServiceConfiguration.config.systemd.services.seter-gateway-adb;
      gatewayServiceTapRequires =
        gatewayServiceConfiguration.config.systemd.services.seter-tap-alpha.requires;
      gatewayServiceFirewallPorts =
        gatewayServiceConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;

      secretPolicyWorkspaces = validWorkspaces // {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "API.Example.COM" ];
          secrets.githubToken = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/github-token";
            hosts = [ "Api.Example.Com" ];
            headers = [
              "Authorization"
              "X-Api-Key"
            ];
          };
        };
      };
      secretPolicyConfiguration = mkHost secretPolicyWorkspaces;
      secretPolicyService = secretPolicyConfiguration.config.systemd.services.seter-proxy;
      secretPolicyFile = builtins.head secretPolicyService.restartTriggers;
      secretPolicyCredentials = secretPolicyService.serviceConfig.LoadCredential;

      hostConfiguration = mkHost validWorkspaces;
      registryFile = hostConfiguration.config.environment.etc."seter/workspaces.json".source;
      minimalStoreSocket = (builtins.head self.nixosConfigurations.minimal.config.microvm.shares).socket;
      alphaDeviceAllow =
        hostConfiguration.config.systemd.services.seter-vm-alpha.serviceConfig.DeviceAllow;
      alphaTapRequires = hostConfiguration.config.systemd.services.seter-tap-alpha.requires;
      dnsService = hostConfiguration.config.systemd.services.seter-dns-alpha;
      proxyService = hostConfiguration.config.systemd.services.seter-proxy;
      proxyPort = hostConfiguration.config.seter.host.proxy.port;
      explicitProxyPort = hostConfiguration.config.seter.host.proxy.explicitPort;
      tcpService = tcpHostConfiguration.config.systemd.services.seter-tcp-egress-alpha;
      tcpTapRequires = tcpHostConfiguration.config.systemd.services.seter-tap-alpha.requires;
      tcpNftablesConfig = tcpHostConfiguration.config.networking.nftables;
      tcpFirewallForwardRules = tcpHostConfiguration.config.networking.firewall.extraForwardRules;
      nftablesConfig = hostConfiguration.config.networking.nftables;
      lifecycleSudoRules = lib.filter (
        rule: builtins.elem "seter-operators" (rule.groups or [ ])
      ) hostConfiguration.config.security.sudo.extraRules;
      lifecycleSudoCommands = lib.concatMap (
        rule: if builtins.elem "seter-operators" (rule.groups or [ ]) then rule.commands else [ ]
      ) hostConfiguration.config.security.sudo.extraRules;
      lifecycleHelper = lib.getExe hostConfiguration.config.seter.host.package;

      fakeRunner = pkgs.runCommand "seter-fake-runner" { } ''
        mkdir -p "$out/bin"
        cat > "$out/bin/microvm-run" <<'EOF'
        #!${pkgs.runtimeShell}
        set -eu
        touch fake-vm-started
        trap 'exit 0' TERM INT
        while true; do
          ${pkgs.coreutils}/bin/sleep 1 &
          wait $! || true
        done
        EOF
        cat > "$out/bin/microvm-shutdown" <<'EOF'
        #!${pkgs.runtimeShell}
        set -eu
        kill -TERM "$MAINPID"
        while kill -0 "$MAINPID" 2>/dev/null; do
          ${pkgs.coreutils}/bin/sleep 0.1
        done
        EOF
        chmod +x "$out/bin/microvm-run" "$out/bin/microvm-shutdown"
      '';

      proxyTestCertificate =
        pkgs.runCommand "seter-proxy-test-certificate"
          {
            nativeBuildInputs = [ pkgs.openssl ];
          }
          ''
            mkdir -p "$out"
            openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
              -subj '/CN=allowed.example' \
              -addext 'subjectAltName=DNS:allowed.example,DNS:second-allowed.example,DNS:passthrough.example' \
              -addext 'basicConstraints=critical,CA:TRUE' \
              -keyout "$out/key.pem" -out "$out/cert.pem"
          '';

      # Public test PKI. The committed private server key protects no real
      # system and exists only to exercise guest trust-store integration.
      proxyTrustCa = ../tests/fixtures/proxy-e2e-ca-cert.pem;
      proxyTrustServerCertificate = ../tests/fixtures/proxy-e2e-server-cert.pem;
      proxyTrustServerKey = ../tests/fixtures/proxy-e2e-server-key.pem;

      explicitProxyRelay = pkgs.writeText "seter-explicit-proxy-relay.py" ''
        import select
        import socket
        import threading

        def relay(client):
            with client:
                request = b""
                while b"\r\n\r\n" not in request and len(request) < 16384:
                    chunk = client.recv(4096)
                    if not chunk:
                        return
                    request += chunk
                if not request.startswith(b"CONNECT proxy-e2e.example:443 HTTP/"):
                    client.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                    return
                with socket.create_connection(("127.0.0.1", 8443)) as upstream:
                    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                    sockets = [client, upstream]
                    while True:
                        readable, _, _ = select.select(sockets, [], [], 10)
                        if not readable:
                            return
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            destination = upstream if source is client else client
                            destination.sendall(data)

        with socket.create_server(("0.0.0.0", 18081), reuse_port=True) as listener:
            while True:
                client, _ = listener.accept()
                threading.Thread(target=relay, args=(client,), daemon=True).start()
      '';

      proxyHttpServer = pkgs.writeText "seter-proxy-test-http-server.py" ''
        import gzip
        import ssl
        import sys
        from functools import partial
        from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
        from pathlib import Path
        from urllib.parse import urlsplit

        class Handler(SimpleHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def send_secret_response(self):
                request_path = urlsplit(self.path).path
                if request_path in ("/secret", "/secret-gzip"):
                    authorization = self.headers.get("Authorization", "")
                    api_key = self.headers.get("X-Api-Key", "")
                    unconfigured = self.headers.get("X-Unconfigured", "")
                    content_length = int(self.headers.get("Content-Length", "0"))
                    request_body = self.rfile.read(content_length) if content_length else b""
                    payload = (
                        authorization.encode()
                        + b"\n"
                        + api_key.encode()
                        + b"\n"
                        + unconfigured.encode()
                        + b"\n"
                        + self.path.encode()
                        + b"\n"
                        + request_body
                        + b"\n"
                    )
                    Path("/tmp/seter-secret-received").write_bytes(payload)
                    encoded_payload = gzip.compress(payload) if request_path == "/secret-gzip" else payload
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("X-Reflected-Authorization", authorization)
                    if request_path == "/secret-gzip":
                        self.send_header("Content-Encoding", "gzip")
                    self.send_header("Content-Length", str(len(encoded_payload)))
                    self.end_headers()
                    self.wfile.write(encoded_payload)
                    return True
                return False

            def do_GET(self):
                if not self.send_secret_response():
                    super().do_GET()

            def do_POST(self):
                if not self.send_secret_response():
                    self.send_error(404)

        handler = partial(Handler, directory="/tmp/seter-upstream")
        port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
        server = ThreadingHTTPServer(("11.0.0.2", port), handler)
        if port == 443:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(sys.argv[2], sys.argv[3])

            def record_server_name(_socket, server_name, _context):
                if server_name == "bad-cert.example":
                    Path("/tmp/seter-bad-cert-tls-seen").touch()

            context.set_servername_callback(record_server_name)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()
      '';

      directTcpClient = pkgs.writeText "seter-direct-tcp-client.py" ''
        import pathlib
        import socket
        import time

        ready = pathlib.Path("/tmp/seter-direct-client-ready")
        send = pathlib.Path("/tmp/seter-direct-client-send")
        blocked = pathlib.Path("/tmp/seter-direct-client-blocked")
        allowed = pathlib.Path("/tmp/seter-direct-client-allowed")

        with socket.create_connection(("11.0.0.2", 2222), timeout=5) as connection:
            ready.touch()
            for _ in range(200):
                if send.exists():
                    break
                time.sleep(0.05)
            else:
                raise SystemExit("timed out waiting for the revocation test")

            connection.settimeout(2)
            try:
                connection.sendall(b"after revocation\n")
                response = connection.recv(1024)
                if response:
                    allowed.write_bytes(response)
                else:
                    blocked.touch()
            except (OSError, TimeoutError):
                blocked.touch()
      '';

      configurationRejected =
        workspaces:
        !(builtins.tryEval (builtins.deepSeq (mkHost workspaces).config.system.build.toplevel.drvPath true))
        .success;

      configurationAccepted =
        workspaces:
        (builtins.tryEval (builtins.deepSeq (mkHost workspaces).config.system.build.toplevel.drvPath true))
        .success;

      hostConfigurationRejected =
        host:
        !(builtins.tryEval (builtins.deepSeq (mkHostWith host).config.system.build.toplevel.drvPath true))
        .success;

      duplicateIpRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          network = validWorkspaces.beta.network // {
            address = validWorkspaces.alpha.network.address;
          };
        };
      };

      duplicateMacRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          network = validWorkspaces.beta.network // {
            mac = validWorkspaces.alpha.network.mac;
          };
        };
      };

      duplicateTapRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          network = validWorkspaces.beta.network // {
            tap = validWorkspaces.alpha.network.tap;
          };
        };
      };

      duplicateHostnameRejected = configurationRejected {
        alpha = validWorkspaces.alpha;
        beta = validWorkspaces.beta // {
          hostname = "alpha.vm";
        };
      };

      invalidIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.999";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      outOfSubnetIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.101.0.12";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      gatewayIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.1";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      networkIpRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.0";
          mac = "02:00:00:00:00:12";
          tap = "seter-broken";
        };
      };

      bridgeTapRejected = configurationRejected {
        broken = mkWorkspace {
          ip = "10.100.0.12";
          mac = "02:00:00:00:00:12";
          tap = "seter0";
        };
      };

      outOfSubnetGatewayRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.host
                hostModuleBase
                {
                  seter.host = {
                    gateway = "10.101.0.1";
                    workspaces = validWorkspaces;
                  };
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      blankInstallableRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          runner.installable = "   ";
        };
      };

      blankKnownHostKeyRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          ssh = validWorkspaces.alpha.ssh // {
            knownHostKey = "   ";
          };
        };
      };

      blankSecretPlaceholderRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "   ";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [ "authorization" ];
          };
        };
      };

      nonDistinctiveSecretPlaceholderRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "placeholder-token";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [ "authorization" ];
          };
        };
      };

      storeSecretSourceRejected = configurationRejected {
        broken = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/nix/store/example-secret";
            hosts = [ "api.example.com" ];
            headers = [ "authorization" ];
          };
        };
      };

      caseInsensitiveSecretHostAccepted = configurationAccepted {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "API.Example.COM" ];
          secrets.token = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [ "Authorization" ];
          };
        };
      };

      duplicateSecretPlaceholderRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets = {
            first = {
              placeholder = "seter-placeholder-0123456789abcdef";
              sourceFile = "/run/secrets/first";
              hosts = [ "api.example.com" ];
              headers = [ "authorization" ];
            };
            second = {
              placeholder = "seter-placeholder-0123456789abcdef";
              sourceFile = "/run/secrets/second";
              hosts = [ "api.example.com" ];
              headers = [ "x-api-key" ];
            };
          };
        };
      };

      overlappingSecretPlaceholderRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets = {
            first = {
              placeholder = "seter-placeholder-0123456789abcdef";
              sourceFile = "/run/secrets/first";
              hosts = [ "api.example.com" ];
              headers = [ "authorization" ];
            };
            second = {
              placeholder = "seter-placeholder-0123456789abcdef-extra";
              sourceFile = "/run/secrets/second";
              hosts = [ "api.example.com" ];
              headers = [ "x-api-key" ];
            };
          };
        };
      };

      invalidSecretNameRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets."bad:name" = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [ "authorization" ];
          };
        };
      };

      passthroughSecretHostRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.passthroughHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [ "authorization" ];
          };
        };
      };

      duplicateSecretHostRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/token";
            hosts = [
              "api.example.com"
              "API.EXAMPLE.COM"
            ];
            headers = [ "authorization" ];
          };
        };
      };

      duplicateSecretHeaderRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [
              "authorization"
              "Authorization"
            ];
          };
        };
      };

      emptySecretHeadersRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [ ];
          };
        };
      };

      prohibitedSecretHeaderRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "api.example.com" ];
          secrets.token = {
            placeholder = "seter-placeholder-0123456789abcdef";
            sourceFile = "/run/secrets/token";
            hosts = [ "api.example.com" ];
            headers = [ "Host" ];
          };
        };
      };

      overlappingProxyHostsRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.httpHosts = [ "API.Example.COM" ];
          egress.passthroughHosts = [ "api.example.com" ];
        };
      };

      proxyPortAsDirectTcpRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          egress.tcp = [
            {
              host = "api.example.com";
              port = 443;
            }
          ];
        };
      };

      proxyPortCollisionRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.host
                hostModuleBase
                {
                  seter.host = {
                    proxy.explicitPort = 18080;
                    workspaces = validWorkspaces;
                  };
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      undefinedHostServiceRejected = configurationRejected {
        alpha = validWorkspaces.alpha // {
          hostServices = [ "missing" ];
        };
      };

      duplicateWorkspaceHostServiceRejected = hostConfigurationRejected {
        gatewayServices.adb = {
          listenPort = 5037;
          targetPort = 15037;
        };
        workspaces.alpha = validWorkspaces.alpha // {
          hostServices = [
            "adb"
            "adb"
          ];
        };
      };

      duplicateGatewayServicePortRejected = hostConfigurationRejected {
        gatewayServices = {
          adb = {
            listenPort = 5037;
            targetPort = 15037;
          };
          builder = {
            listenPort = 5037;
            targetPort = 15038;
          };
        };
        workspaces = validWorkspaces;
      };

      gatewayServiceProxyPortRejected = hostConfigurationRejected {
        gatewayServices.bad = {
          listenPort = 18080;
          targetPort = 15037;
        };
        workspaces = validWorkspaces;
      };

      gatewayServiceDnsPortRejected = hostConfigurationRejected {
        gatewayServices.bad = {
          listenPort = alphaDnsPort;
          targetPort = 15037;
        };
        workspaces = validWorkspaces;
      };

      invalidGatewayServiceNameRejected = hostConfigurationRejected {
        gatewayServices."Bad_Name" = {
          listenPort = 5037;
          targetPort = 15037;
        };
        workspaces = validWorkspaces;
      };

      nonLoopbackGatewayTargetRejected = hostConfigurationRejected {
        gatewayServices.bad = {
          listenPort = 5037;
          targetAddress = "192.0.2.10";
          targetPort = 15037;
        };
        workspaces = validWorkspaces // {
          alpha = validWorkspaces.alpha // {
            hostServices = [ "bad" ];
          };
        };
      };

      tcpWithoutFirewallRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.host
                hostModuleBase
                {
                  networking.firewall.enable = false;
                  seter.host.workspaces = tcpTestWorkspaces;
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      tcpWithoutForwardFilterRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.host
                hostModuleBase
                {
                  networking.firewall.filterForward = false;
                  seter.host.workspaces = tcpTestWorkspaces;
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      guestPrivateProxyKeyRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.guest
                {
                  seter.guest = {
                    enable = true;
                    proxyCaCertificate = ''
                      -----BEGIN CERTIFICATE-----
                      invalid-test-certificate
                      -----END CERTIFICATE-----
                      -----BEGIN PRIVATE KEY-----
                      must-never-enter-the-store
                      -----END PRIVATE KEY-----
                    '';
                  };
                  system.stateVersion = "24.11";
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      invalidGuestPlaceholderNameRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.guest
                {
                  seter.guest = {
                    enable = true;
                    secretPlaceholders."INVALID-NAME" = "seter-placeholder-invalid-0123456789abcdef";
                  };
                  system.stateVersion = "24.11";
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      invalidGuestPlaceholderValueRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.guest
                {
                  seter.guest = {
                    enable = true;
                    secretPlaceholders.GITHUB_TOKEN = "this-would-be-a-real-secret";
                  };
                  system.stateVersion = "24.11";
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      proxyGuestPlaceholderNameRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.guest
                {
                  seter.guest = {
                    enable = true;
                    secretPlaceholders.HTTPS_PROXY = "seter-placeholder-invalid-0123456789abcdef";
                  };
                  system.stateVersion = "24.11";
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;

      overlappingGuestPlaceholdersRejected =
        !(builtins.tryEval (
          builtins.deepSeq
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.guest
                {
                  seter.guest = {
                    enable = true;
                    secretPlaceholders = {
                      FIRST_TOKEN = "seter-placeholder-0123456789abcdef";
                      SECOND_TOKEN = "seter-placeholder-0123456789abcdef-extra";
                    };
                  };
                  system.stateVersion = "24.11";
                }
              ];
            }).config.system.build.toplevel.drvPath
            true
        )).success;
    in
    {
      checks = {
        inherit (self.packages.${system}) seter;

        nixos-host-module = hostConfiguration.config.system.build.toplevel;

        workspace-registry =
          assert minimalStoreSocket == "/run/seter/minimal/virtiofs-ro-store.sock";
          assert builtins.elem "vhost_vsock" hostConfiguration.config.boot.kernelModules;
          assert builtins.elem "/dev/vhost-vsock rw" alphaDeviceAllow;
          assert builtins.elem "nftables.service" alphaTapRequires;
          assert builtins.elem "seter-dns-alpha.service" alphaTapRequires;
          assert builtins.elem "seter-proxy.service" alphaTapRequires;
          assert builtins.elem "seter-bridge.service" dnsService.requires;
          assert builtins.elem "nftables.service" dnsService.requires;
          assert builtins.elem "seter-bridge.service" proxyService.requires;
          assert builtins.elem "nftables.service" proxyService.requires;
          assert alphaDnsPort == alphaDnsPortWithEarlierWorkspace;
          assert alphaDnsPort != betaDnsPort;
          assert builtins.elem "alpha.vm" hostConfiguration.config.networking.hosts."10.100.0.10";
          assert builtins.elem alphaDnsPort
            hostConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;
          assert builtins.elem alphaDnsPort
            hostConfiguration.config.networking.firewall.interfaces.seter0.allowedUDPPorts;
          assert builtins.elem proxyPort
            hostConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;
          assert builtins.elem explicitProxyPort
            hostConfiguration.config.networking.firewall.interfaces.seter0.allowedTCPPorts;
          assert builtins.elem 5037 gatewayServiceFirewallPorts;
          assert builtins.elem "seter-gateway-adb.socket" gatewayServiceTapRequires;
          assert builtins.elem "seter-bridge.service" gatewayServiceSocket.requires;
          assert builtins.elem "nftables.service" gatewayServiceSocket.requires;
          assert gatewayServiceSocket.unitConfig.StopWhenUnneeded;
          assert gatewayService.serviceConfig.DynamicUser;
          assert lib.hasInfix "systemd-socket-proxyd --exit-idle-time=5s 127.0.0.1:15037"
            gatewayService.serviceConfig.ExecStart;
          assert nftablesConfig.enable;
          assert nftablesConfig.tables.seter_l2.family == "bridge";
          assert nftablesConfig.tables.seter_l3.family == "inet";
          assert nftablesConfig.tables.seter_dns.family == "inet";
          assert nftablesConfig.tables.seter_proxy.family == "inet";
          assert nftablesConfig.tables.seter_proxy_output.family == "inet";
          assert builtins.elem "seter-tcp-egress-alpha.service" tcpTapRequires;
          assert builtins.elem "nftables.service" tcpService.requires;
          assert tcpNftablesConfig.tables.seter_tcp_nat.family == "ip";
          assert tcpHostConfiguration.config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1;
          assert tcpHostConfiguration.config.networking.firewall.filterForward;
          assert lib.hasInfix ''iifname "seter0"'' tcpFirewallForwardRules;
          assert lib.hasInfix "10.100.0.10" tcpFirewallForwardRules;
          assert builtins.any (
            entry: entry.command == "${lifecycleHelper} __start alpha" && builtins.elem "NOPASSWD" entry.options
          ) lifecycleSudoCommands;
          assert builtins.any (
            entry: entry.command == "${lifecycleHelper} __stop alpha" && builtins.elem "NOPASSWD" entry.options
          ) lifecycleSudoCommands;
          assert lib.all (rule: rule.runAs == "root") lifecycleSudoRules;
          assert lib.all (entry: !(lib.hasInfix "*" entry.command)) lifecycleSudoCommands;
          assert proxyService.serviceConfig.LoadCredential == [ ];
          assert
            secretPolicyCredentials == [
              "seter-alpha.githubToken:/run/secrets/github-token"
            ];
          pkgs.runCommand "seter-workspace-registry-check"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.util-linux
                self.packages.${system}.seter
              ];
            }
            ''
              jq -e '
                .version == 2 and
                (.workspaces | keys == ["alpha", "beta"]) and
                (.workspaces.alpha.hostname == "alpha.vm") and
                (.workspaces.alpha.network.address == "10.100.0.10") and
                (.workspaces.alpha.network.mac == "02:00:00:00:00:10") and
                (.workspaces.alpha.resources.memoryMiB == 4096) and
                (.workspaces.alpha.resources.cpuQuotaPercent == 200) and
                (.workspaces.alpha.ssh.knownHostKey == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey alpha-test") and
                (.workspaces.alpha.storage.image == "alpha-project.img") and
                (.workspaces.alpha | has("egress") | not) and
                (.workspaces.alpha | has("secrets") | not) and
                (.workspaces.alpha | has("hostServices") | not)
              ' ${registryFile}

              jq -e '
                .version == 2 and
                (.workspaces["10.100.0.10"].name == "alpha") and
                (.workspaces["10.100.0.10"].httpHosts == ["api.example.com"]) and
                (.workspaces["10.100.0.10"].passthroughHosts == []) and
                (.workspaces["10.100.0.10"].secrets.githubToken == {
                  credential: "seter-alpha.githubToken",
                  placeholder: "seter-placeholder-0123456789abcdef",
                  hosts: ["api.example.com"],
                  headers: ["authorization", "x-api-key"]
                }) and
                (.workspaces["10.100.0.10"].secrets.githubToken | has("sourceFile") | not) and
                (.workspaces["10.100.0.11"].secrets == {})
              ' ${secretPolicyFile}

              ! grep -Fq '/run/secrets/github-token' ${secretPolicyFile}

              export SETER_REGISTRY=${registryFile}
              test "$(seter list)" = $'alpha\nbeta'
              test "$(seter ip alpha)" = "10.100.0.10"

              mkdir -p test-bin
              cat > test-bin/systemctl <<'EOF'
              #!${pkgs.runtimeShell}
              if test "$1" = show; then
                printf '%s\n' ActiveState=inactive SubState=dead MainPID=0
              fi
              EOF
              cat > test-bin/nix <<'EOF'
              #!${pkgs.runtimeShell}
              echo ${fakeRunner}
              EOF
              cat > test-bin/debugfs <<'EOF'
              #!${pkgs.runtimeShell}
              echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey seter-test'
              EOF
              cat > test-bin/ssh-keygen <<'EOF'
              #!${pkgs.runtimeShell}
              echo '256 SHA256:test seter-test (ED25519)'
              EOF
              chmod +x test-bin/systemctl test-bin/nix test-bin/debugfs test-bin/ssh-keygen
              export SETER_SYSTEMCTL=$PWD/test-bin/systemctl
              export SETER_NIX=$PWD/test-bin/nix
              export SETER_STATE_DIR=$PWD/state
              export SETER_GCROOT_DIR=$PWD/gcroots
              seter update alpha
              test "$(readlink state/alpha/current)" = "${fakeRunner}"
              test "$(readlink gcroots/alpha)" = "${fakeRunner}"
              test -z "$(find gcroots -maxdepth 1 -name '.alpha.pending-*' -print -quit)"
              set +e
              seter status alpha > status
              status_code=$?
              set -e
              test "$status_code" = 3
              grep -F 'state: stopped' status
              touch state/alpha/alpha-project.img
              export SETER_DEBUGFS=$PWD/test-bin/debugfs
              export SETER_SSH_KEYGEN=$PWD/test-bin/ssh-keygen

              (
                flock --exclusive 9
                touch host-key-lock-held
                sleep 30
              ) 9>state/alpha/lifecycle.lock &
              lock_pid=$!
              for attempt in $(seq 1 100); do
                test -e host-key-lock-held && break
                sleep 0.01
              done
              test -e host-key-lock-held
              set +e
              seter ssh-host-key alpha > /dev/null 2> host-key-lock-error
              lock_code=$?
              set -e
              test "$lock_code" = 1
              grep -F 'workspace lifecycle is busy' host-key-lock-error
              kill "$lock_pid"
              wait "$lock_pid" 2>/dev/null || true

              seter ssh-host-key alpha > host-key 2> fingerprint
              grep -F 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey' host-key
              grep -F 'SHA256:test' fingerprint

              rm gcroots/alpha
              mkdir gcroots/alpha
              set +e
              seter update alpha > /dev/null 2> gcroot-error
              update_code=$?
              set -e
              test "$update_code" = 1
              grep -F 'it was retained to protect the installed runner' gcroot-error
              pending=$(find gcroots -maxdepth 1 -type l -name '.alpha.pending-*' -print -quit)
              test -n "$pending"
              test "$(readlink "$pending")" = "${fakeRunner}"
              test "$(readlink state/alpha/current)" = "${fakeRunner}"

              touch "$out"
            '';

        workspace-uniqueness =
          assert duplicateIpRejected;
          assert duplicateMacRejected;
          assert duplicateTapRejected;
          assert duplicateHostnameRejected;
          assert invalidIpRejected;
          assert outOfSubnetIpRejected;
          assert gatewayIpRejected;
          assert networkIpRejected;
          assert bridgeTapRejected;
          assert outOfSubnetGatewayRejected;
          assert blankInstallableRejected;
          assert blankKnownHostKeyRejected;
          assert blankSecretPlaceholderRejected;
          assert nonDistinctiveSecretPlaceholderRejected;
          assert storeSecretSourceRejected;
          assert caseInsensitiveSecretHostAccepted;
          assert duplicateSecretPlaceholderRejected;
          assert overlappingSecretPlaceholderRejected;
          assert invalidSecretNameRejected;
          assert passthroughSecretHostRejected;
          assert duplicateSecretHostRejected;
          assert duplicateSecretHeaderRejected;
          assert emptySecretHeadersRejected;
          assert prohibitedSecretHeaderRejected;
          assert overlappingProxyHostsRejected;
          assert proxyPortAsDirectTcpRejected;
          assert proxyPortCollisionRejected;
          assert undefinedHostServiceRejected;
          assert duplicateWorkspaceHostServiceRejected;
          assert duplicateGatewayServicePortRejected;
          assert gatewayServiceProxyPortRejected;
          assert gatewayServiceDnsPortRejected;
          assert invalidGatewayServiceNameRejected;
          assert nonLoopbackGatewayTargetRejected;
          assert tcpWithoutFirewallRejected;
          assert tcpWithoutForwardFilterRejected;
          assert guestPrivateProxyKeyRejected;
          assert invalidGuestPlaceholderNameRejected;
          assert invalidGuestPlaceholderValueRejected;
          assert proxyGuestPlaceholderNameRejected;
          assert overlappingGuestPlaceholdersRejected;
          pkgs.runCommand "seter-workspace-uniqueness-check" { } ''
            touch "$out"
          '';

        nixos-guest-module =
          let
            # Public, self-signed test CA. The matching private key is
            # deliberately not retained in the repository.
            proxyCaCertificate = builtins.readFile proxyTrustCa;
            guestConfiguration = inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.guest
                {
                  seter.guest = {
                    enable = true;
                    network.enable = true;
                    proxyCaCertificate = proxyCaCertificate;
                    secretPlaceholders = {
                      GITHUB_TOKEN = "seter-placeholder-github-0123456789abcdef";
                      GH_TOKEN = "seter-placeholder-github-0123456789abcdef";
                    };
                  };
                  system.stateVersion = "24.11";
                }
              ];
            };
            sessionVariables = guestConfiguration.config.environment.sessionVariables;
          in
          assert sessionVariables.HTTP_PROXY == "http://10.100.0.1:18081";
          assert sessionVariables.HTTPS_PROXY == "http://10.100.0.1:18081";
          assert sessionVariables.NO_PROXY == "127.0.0.1,localhost,::1,10.100.0.10";
          assert sessionVariables.GITHUB_TOKEN == "seter-placeholder-github-0123456789abcdef";
          assert sessionVariables.GH_TOKEN == sessionVariables.GITHUB_TOKEN;
          assert builtins.elem proxyCaCertificate guestConfiguration.config.security.pki.certificates;
          guestConfiguration.config.system.build.toplevel;

      }
      // lib.optionalAttrs (system == "x86_64-linux") {
        minimal-runner = self.nixosConfigurations.minimal.config.microvm.declaredRunner;

        lifecycle-e2e = import ../tests/lifecycle-e2e.nix {
          inherit
            inputs
            self
            pkgs
            system
            ;
        };

        proxy-trust-e2e = pkgs.testers.runNixOSTest {
          name = "seter-proxy-trust-e2e";

          nodes = {
            guest =
              { lib, ... }:
              {
                imports = [ self.nixosModules.guest ];
                # The microvm module's package overlay is needed for runners,
                # but this check boots the guest configuration directly as a
                # NixOS test node whose package set is intentionally read-only.
                nixpkgs.overlays = lib.mkForce [ ];

                environment.systemPackages = [ pkgs.curl ];
                users.users.tester.isNormalUser = true;

                seter.guest = {
                  enable = true;
                  network.enable = false;
                  projectVolume.enable = false;
                  ssh.enable = false;
                  proxy = "http://proxy:18081";
                  proxyCaCertificate = builtins.readFile proxyTrustCa;
                  secretPlaceholders.GITHUB_TOKEN = "seter-placeholder-github-0123456789abcdef";
                };

                virtualisation.memorySize = 1024;
                system.stateVersion = "24.11";
              };

            proxy = {
              environment.systemPackages = [ pkgs.python3 ];
              networking.firewall.allowedTCPPorts = [ 18081 ];
              virtualisation.memorySize = 768;
              system.stateVersion = "24.11";
            };
          };

          testScript = ''
            start_all()

            proxy.succeed("mkdir -p /tmp/seter-proxy-trust-upstream; printf 'trusted proxy e2e\\n' > /tmp/seter-proxy-trust-upstream/index.html")
            proxy.succeed("systemd-run --unit=seter-proxy-trust-upstream --property=Type=simple -- ${pkgs.runtimeShell} -c 'cd /tmp/seter-proxy-trust-upstream && exec ${lib.getExe pkgs.openssl} s_server -quiet -accept 127.0.0.1:8443 -cert ${proxyTrustServerCertificate} -key ${proxyTrustServerKey} -WWW'")
            proxy.wait_for_unit("seter-proxy-trust-upstream.service")
            proxy.succeed("systemd-run --unit=seter-proxy-trust-relay --property=Type=simple -- ${pkgs.python3}/bin/python ${explicitProxyRelay}")
            proxy.wait_for_unit("seter-proxy-trust-relay.service")

            guest.wait_until_succeeds("getent ahostsv4 proxy")
            guest.succeed("su - tester -c 'test \"$HTTPS_PROXY\" = http://proxy:18081; test \"$NO_PROXY\" = 127.0.0.1,localhost,::1'")
            guest.succeed("su - tester -c 'test \"$GITHUB_TOKEN\" = seter-placeholder-github-0123456789abcdef'")
            guest.wait_until_succeeds("su - tester -c 'curl --fail --silent https://proxy-e2e.example/index.html | grep -F \"trusted proxy e2e\"'")
          '';
        };

        host-runtime = pkgs.testers.runNixOSTest {
          name = "seter-host-runtime";

          nodes.machine = {
            imports = [ self.nixosModules.host ];

            environment.systemPackages = [ self.packages.${system}.seter ];

            users.users.operator = {
              isNormalUser = true;
              extraGroups = [ "seter-operators" ];
            };
            users.users.outsider.isNormalUser = true;

            seter.host = {
              enable = true;
              workspaces.alpha = validWorkspaces.alpha;
            };

            virtualisation.memorySize = 1024;
            system.stateVersion = "24.11";
          };

          testScript = ''
            start_all()

            machine.wait_for_unit("seter-bridge.service")
            machine.wait_for_unit("nftables.service")
            machine.wait_for_unit("seter-proxy.service")
            machine.succeed("seter proxy-ca > /tmp/seter-proxy-ca.pem 2> /tmp/seter-proxy-ca-fingerprint")
            machine.succeed("cmp /tmp/seter-proxy-ca.pem /var/lib/seter-proxy-public/seter-proxy-ca-cert.pem")
            machine.succeed("grep -F 'sha256 Fingerprint=' /tmp/seter-proxy-ca-fingerprint")
            machine.succeed("runuser -u outsider -- seter proxy-ca > /tmp/outsider-proxy-ca.pem 2> /tmp/outsider-proxy-ca-fingerprint")
            machine.succeed("cmp /tmp/outsider-proxy-ca.pem /tmp/seter-proxy-ca.pem")
            machine.succeed("test $(stat -c %a /var/lib/seter-proxy) = 700")
            machine.succeed("test $(stat -c %a /var/lib/seter-proxy-public) = 755")
            machine.fail("runuser -u outsider -- test -r /var/lib/seter-proxy/mitmproxy-ca.pem")
            machine.fail("runuser -u outsider -- test -r /var/lib/seter-proxy/mitmproxy-ca.p12")
            machine.succeed("systemctl restart seter-proxy.service; cmp /tmp/seter-proxy-ca.pem /var/lib/seter-proxy-public/seter-proxy-ca-cert.pem")
            machine.fail("systemctl is-active --quiet seter-dns-alpha.service")
            machine.succeed("nft list table bridge seter_l2")
            machine.succeed("nft list table inet seter_l3")
            machine.succeed("nft list table inet seter_dns")
            machine.succeed("nft list table inet seter_proxy")
            machine.succeed("ip link show dev seter0")
            machine.succeed("ip -4 address show dev seter0 | grep -F '10.100.0.1/24'")
            machine.fail("ip link show dev seter-alpha")

            machine.succeed("systemctl start seter-runtime-alpha.target")
            machine.wait_for_unit("seter-dns-alpha.service")
            machine.wait_for_unit("seter-tap-alpha.service")
            machine.wait_for_unit("seter-virtiofsd-alpha.service")
            machine.succeed("ip link show dev seter-alpha | grep -F 'master seter0'")
            machine.succeed("bridge -details link show dev seter-alpha | grep -F 'isolated on'")
            machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); uid=$(id -u $account); ip tuntap show dev seter-alpha | grep -F \"user $uid\"")
            machine.succeed("test $(stat -c %a /var/lib/seter/workspaces/alpha) = 700")
            machine.succeed("account=$(stat -c %G /run/lock/seter/alpha.lock); test \"$account\" = $(stat -c %U /var/lib/seter/workspaces/alpha)")
            machine.succeed("test $(stat -c %U /run/lock/seter/alpha.lock) = root")
            machine.succeed("test $(stat -c %a /run/lock/seter/alpha.lock) = 640")
            machine.fail("account=$(stat -c %G /run/lock/seter/alpha.lock); runuser -u $account -- rm -f /run/lock/seter/alpha.lock")
            machine.succeed("ip tuntap show dev seter-alpha | grep -F 'multi_queue'")
            machine.succeed("test -S /run/seter/alpha/virtiofs-ro-store.sock")
            machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); uid=$(id -u $account); main=$(systemctl show --value --property MainPID seter-virtiofsd-alpha.service); test $(awk '/^Uid:/ { print $2 }' /proc/$main/status) = $uid")
            machine.succeed("stat -c %A /run/seter/alpha/virtiofs-ro-store.sock | grep -E '^s[rwx-]{6}---$'")
            machine.succeed("stat -c %G /run/seter/alpha/virtiofs-ro-store.sock | grep -E '^seter-alpha-[0-9a-f]{8}$'")
            machine.succeed("main=$(systemctl show --value --property MainPID seter-virtiofsd-alpha.service); for pid in $(cat /proc/$main/task/$main/children); do tr '\\0' ' ' < /proc/$pid/cmdline; done | grep -F -- '--shared-dir=/nix/store'")
            machine.succeed("main=$(systemctl show --value --property MainPID seter-virtiofsd-alpha.service); for pid in $(cat /proc/$main/task/$main/children); do tr '\\0' ' ' < /proc/$pid/cmdline; done | grep -F -- '--readonly'")

            machine.succeed("systemctl stop seter-runtime-alpha.target")
            machine.wait_until_fails("ip link show dev seter-alpha")
            machine.wait_until_fails("test -e /run/seter/alpha/virtiofs-ro-store.sock")
            machine.wait_until_fails("systemctl is-active --quiet seter-dns-alpha.service")
            machine.succeed("test $(systemctl show --value --property Result seter-virtiofsd-alpha.service) = success")
            machine.succeed("systemctl is-active --quiet seter-bridge.service")
            machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

            machine.succeed("mkdir -p /nix/var/nix/gcroots/per-project; ln -s ${fakeRunner} /nix/var/nix/gcroots/per-project/alpha")
            machine.succeed("ln -s ${fakeRunner} /var/lib/seter/workspaces/alpha/current")
            machine.succeed("set +e; seter status alpha > /tmp/seter-status; code=$?; set -e; test $code = 3; grep -F 'state: stopped' /tmp/seter-status")
            machine.fail("su - outsider -c 'seter up alpha'")
            machine.succeed("set +e; su - operator -c 'seter up missing' 2> /tmp/missing-workspace; code=$?; set -e; test $code = 1; grep -F 'is not configured' /tmp/missing-workspace")
            machine.fail("su - operator -c 'sudo -n true'")
            machine.fail("su - operator -c 'sudo -n -u outsider ${lifecycleHelper} __start alpha'")
            machine.fail("su - operator -c 'seter __start alpha'")
            machine.succeed("su - operator -c 'seter up alpha' | grep -F 'Started alpha at 10.100.0.10'")
            machine.wait_for_unit("seter-vm-alpha.service")
            machine.wait_until_succeeds("test -e /var/lib/seter/workspaces/alpha/fake-vm-started")
            machine.succeed("test $(readlink /var/lib/seter/workspaces/alpha/booted) = ${fakeRunner}")
            machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); main=$(systemctl show --value --property MainPID seter-vm-alpha.service); test $(awk '/^Name:/ { print $2 }' /proc/$main/status) = microvm-run")
            machine.succeed("test $(systemctl show --value --property MemoryMax seter-vm-alpha.service) = 4294967296")
            machine.succeed("test $(systemctl show --value --property CPUQuotaPerSecUSec seter-vm-alpha.service) = 2s")
            machine.succeed("systemctl is-active --quiet seter-runtime-alpha.target")
            machine.fail("flock --nonblock /run/lock/seter/alpha.lock true")
            machine.succeed("seter status alpha | grep -F 'state: running'")
            machine.succeed("set +e; seter update alpha > /tmp/seter-update 2>&1; code=$?; set -e; test $code = 1; grep -F 'stop it before updating' /tmp/seter-update")
            machine.succeed("su - operator -c 'seter down alpha' | grep -F 'Stopped alpha'")
            machine.wait_until_fails("test -e /var/lib/seter/workspaces/alpha/booted")
            machine.succeed("flock --nonblock /run/lock/seter/alpha.lock true")
            machine.wait_until_fails("ip link show dev seter-alpha")
            machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

            machine.succeed("systemctl stop seter-bridge.service")
            machine.succeed("ip link add name seter0 type bridge")
            machine.fail("systemctl start seter-bridge.service")
            machine.succeed("ip link show dev seter0")
            machine.succeed("ip link delete dev seter0")
            machine.succeed("systemctl reset-failed seter-bridge.service")
          '';
        };

        network-isolation = pkgs.testers.runNixOSTest {
          name = "seter-network-isolation";

          nodes.machine = {
            imports = [ self.nixosModules.host ];

            environment.systemPackages = [
              pkgs.bind
              pkgs.curl
              pkgs.dnsmasq
              pkgs.iproute2
              pkgs.iputils
              pkgs.jq
              pkgs.nftables
              pkgs.openssl
            ];

            # Direct TCP enables kernel forwarding, while the NixOS forwarding
            # firewall must continue to reject traffic unrelated to Seter.
            networking.firewall.enable = true;
            networking.hosts."11.0.0.2" = [
              "allowed.example"
              "bad-cert.example"
              "passthrough.example"
              "second-allowed.example"
            ];
            networking.hosts."127.0.0.1" = [
              "private.example"
              "private-passthrough.example"
            ];
            networking.hosts."224.0.0.1" = [ "multicast.example" ];
            # Exercise the strongest reload mode: Seter's managed tables must
            # be recreated as part of the same transaction after a full flush.
            networking.nftables.flushRuleset = true;

            # The test creates the credential source at runtime so the proxy
            # unit can prove both missing-source failure and systemd's private
            # credential snapshot behavior.
            systemd.services.seter-proxy.wantedBy = lib.mkForce [ ];
            # Keep the shared gateway socket needed while network namespaces
            # stand in for generated TAP units. This remains available across
            # the specialisation switch used by the revocation test.
            systemd.services.seter-test-gateway-consumer = {
              requires = [ "seter-gateway-adb.socket" ];
              after = [ "seter-gateway-adb.socket" ];
              serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            };

            seter.host = {
              enable = true;
              dns.upstreamServers = [ "11.0.0.2" ];
              proxy.upstreamCaFile = "${proxyTestCertificate}/cert.pem";
              tcpEgress.refreshIntervalSeconds = 300;
              gatewayServices.adb = {
                listenPort = 5037;
                targetPort = 15037;
              };
              workspaces = validWorkspaces // {
                alpha = validWorkspaces.alpha // {
                  hostServices = [ "adb" ];
                  egress.httpHosts = [
                    "allowed.example"
                    "bad-cert.example"
                    "multicast.example"
                    "private.example"
                    "second-allowed.example"
                  ];
                  egress.passthroughHosts = [
                    "passthrough.example"
                    "private-passthrough.example"
                  ];
                  egress.tcp = [
                    {
                      host = "direct.example";
                      port = 2222;
                    }
                    {
                      host = "rebind.example";
                      port = 2224;
                    }
                    {
                      host = "multicast.example";
                      port = 2225;
                    }
                  ];
                  secrets.githubToken = {
                    placeholder = "seter-placeholder-0123456789abcdef";
                    sourceFile = "/run/seter-test/github-token";
                    hosts = [
                      "allowed.example"
                      # Exercise the guarantee that upstream certificate
                      # verification happens before an injected request can
                      # reach a destination with the wrong certificate.
                      "bad-cert.example"
                    ];
                    headers = [ "authorization" ];
                  };
                  secrets.otherToken = {
                    placeholder = "seter-placeholder-fedcba9876543210";
                    sourceFile = "/run/seter-test/other-token";
                    hosts = [ "second-allowed.example" ];
                    headers = [ "x-api-key" ];
                  };
                };
                beta = validWorkspaces.beta // {
                  # Exercise a workspace that may contact an intercepted host
                  # but has no credential bound to it.
                  egress.httpHosts = [ "second-allowed.example" ];
                };
              };
            };

            # Exercise runtime authorization revocation without removing the
            # shared relay: hand the same service from alpha to beta so the
            # authorization restart trigger must terminate alpha's live flow.
            specialisation.gateway-revoked.configuration = {
              seter.host.workspaces.alpha.hostServices = lib.mkForce [ ];
              seter.host.workspaces.beta.hostServices = lib.mkForce [ "adb" ];
            };

            virtualisation.memorySize = 1024;
            system.stateVersion = "24.11";
          };

          testScript = ''
            start_all()

            machine.wait_for_unit("seter-bridge.service")
            machine.wait_for_unit("nftables.service")
            # Model the TAP's Requires= edge while this test uses lightweight
            # network namespaces in place of the generated TAP service.
            machine.succeed("systemctl start seter-test-gateway-consumer.service")
            machine.wait_for_unit("seter-gateway-adb.socket")
            # LoadCredential must fail closed while its root-only source is
            # absent. Once present, PID 1 snapshots it into the service's
            # private mount namespace for the unprivileged proxy account.
            machine.fail("systemctl start seter-proxy.service")
            machine.succeed("systemctl stop seter-proxy.service; systemctl reset-failed seter-proxy.service")
            machine.succeed("install -d -m 0700 /run/seter-test; printf other-runtime-token > /run/seter-test/other-token; chmod 0400 /run/seter-test/other-token")

            # Invalid runtime values fail during addon configuration rather
            # than entering a request header.
            machine.succeed(": > /run/seter-test/github-token; chmod 0400 /run/seter-test/github-token")
            machine.fail("systemctl start seter-proxy.service")
            machine.succeed("systemctl stop seter-proxy.service; systemctl reset-failed seter-proxy.service")
            machine.succeed("printf short > /run/seter-test/github-token")
            machine.fail("systemctl start seter-proxy.service")
            machine.succeed("systemctl stop seter-proxy.service; systemctl reset-failed seter-proxy.service")
            machine.succeed("printf w6ljcmVkZW50aWFs | ${pkgs.coreutils}/bin/base64 -d > /run/seter-test/github-token")
            machine.fail("systemctl start seter-proxy.service")
            machine.succeed("systemctl stop seter-proxy.service; systemctl reset-failed seter-proxy.service")
            machine.succeed("printf dG9rZW4BdmFsdWU= | ${pkgs.coreutils}/bin/base64 -d > /run/seter-test/github-token")
            machine.fail("systemctl start seter-proxy.service")
            machine.succeed("systemctl stop seter-proxy.service; systemctl reset-failed seter-proxy.service")
            machine.succeed("head -c 16385 /dev/zero | tr '\0' x > /run/seter-test/github-token")
            machine.fail("systemctl start seter-proxy.service")
            machine.succeed("systemctl stop seter-proxy.service; systemctl reset-failed seter-proxy.service")

            machine.succeed("printf first-runtime-token > /run/seter-test/github-token; chmod 0400 /run/seter-test/github-token")
            machine.fail("${pkgs.util-linux}/bin/runuser -u seter-proxy -- ${pkgs.coreutils}/bin/cat /run/seter-test/github-token")
            machine.succeed("systemctl start seter-proxy.service")
            machine.wait_for_unit("seter-proxy.service")
            machine.succeed("pid=$(systemctl show --value --property MainPID seter-proxy.service); credential_dir=$(tr '\\0' '\\n' < /proc/$pid/environ | ${pkgs.gnused}/bin/sed -n 's/^CREDENTIALS_DIRECTORY=//p'); test -n \"$credential_dir\"; test \"$(${pkgs.util-linux}/bin/nsenter --target \"$pid\" --mount -- ${pkgs.util-linux}/bin/runuser -u seter-proxy -- ${pkgs.coreutils}/bin/cat \"$credential_dir/seter-alpha.githubToken\")\" = first-runtime-token")
            machine.fail("grep -F first-runtime-token /etc/systemd/system/seter-proxy.service")
            machine.fail("pid=$(systemctl show --value --property MainPID seter-proxy.service); tr '\\0' '\\n' < /proc/$pid/environ | grep -F first-runtime-token")
            machine.fail("pid=$(systemctl show --value --property MainPID seter-proxy.service); tr '\\0' ' ' < /proc/$pid/cmdline | grep -F first-runtime-token")
            machine.fail("journalctl -u seter-proxy.service | grep -F first-runtime-token")

            # LoadCredential is intentionally a start-time snapshot. Secret
            # managers must restart the service after rotating a source file.
            machine.succeed("printf 'rotated-runtime-token\\r\\n' > /run/seter-test/github-token; chmod 0400 /run/seter-test/github-token")
            machine.succeed("pid=$(systemctl show --value --property MainPID seter-proxy.service); credential_dir=$(tr '\\0' '\\n' < /proc/$pid/environ | ${pkgs.gnused}/bin/sed -n 's/^CREDENTIALS_DIRECTORY=//p'); test \"$(${pkgs.util-linux}/bin/nsenter --target \"$pid\" --mount -- ${pkgs.util-linux}/bin/runuser -u seter-proxy -- ${pkgs.coreutils}/bin/cat \"$credential_dir/seter-alpha.githubToken\")\" = first-runtime-token")
            machine.succeed("systemctl restart seter-proxy.service")
            machine.wait_for_unit("seter-proxy.service")
            machine.succeed("pid=$(systemctl show --value --property MainPID seter-proxy.service); credential_dir=$(tr '\\0' '\\n' < /proc/$pid/environ | ${pkgs.gnused}/bin/sed -n 's/^CREDENTIALS_DIRECTORY=//p'); test \"$(${pkgs.util-linux}/bin/nsenter --target \"$pid\" --mount -- ${pkgs.util-linux}/bin/runuser -u seter-proxy -- ${pkgs.coreutils}/bin/base64 -w0 \"$credential_dir/seter-alpha.githubToken\")\" = cm90YXRlZC1ydW50aW1lLXRva2VuDQo=")
            machine.fail("grep -F rotated-runtime-token /etc/systemd/system/seter-proxy.service")
            machine.fail("journalctl -u seter-proxy.service | grep -F rotated-runtime-token")
            machine.succeed("systemctl start seter-dns-alpha.service seter-dns-beta.service")
            machine.wait_for_unit("seter-dns-alpha.service")
            machine.wait_for_unit("seter-dns-beta.service")
            machine.succeed("nft list table bridge seter_l2")
            machine.succeed("nft list table inet seter_l3")
            machine.succeed("nft list table inet seter_dns")
            machine.succeed("nft list table inet seter_proxy")
            machine.succeed("nft list table inet seter_proxy_output")
            machine.succeed("nft list table ip seter_tcp_nat")
            machine.succeed("test $(sysctl -n net.ipv4.ip_forward) = 1")

            # Use network namespaces as lightweight hostile guests. Their host
            # veth names and guest identities match the registered TAPs, so
            # packets traverse the exact generated nftables rules.
            machine.succeed("ip netns add alpha; ip link add seter-alpha type veth peer name eth0 netns alpha")
            machine.succeed("ip link set seter-alpha master seter0; bridge link set dev seter-alpha isolated on; ip link set seter-alpha up")
            machine.succeed("ip -n alpha link set lo up; ip -n alpha link set eth0 address 02:00:00:00:00:10; ip -n alpha link set eth0 up; ip -n alpha address add 10.100.0.10/24 dev eth0; ip -n alpha route add default via 10.100.0.1")

            machine.succeed("ip netns add beta; ip link add seter-beta type veth peer name eth0 netns beta")
            machine.succeed("ip link set seter-beta master seter0; bridge link set dev seter-beta isolated on; ip link set seter-beta up")
            machine.succeed("ip -n beta link set lo up; ip -n beta link set eth0 address 02:00:00:00:00:11; ip -n beta link set eth0 up; ip -n beta address add 10.100.0.11/24 dev eth0; ip -n beta route add default via 10.100.0.1")

            # Named gateway services expose a fixed loopback daemon only to
            # explicitly authorized workspaces. An unavailable target fails
            # closed; another workspace, the target's loopback port, another
            # host port, and the same port on a routed address remain denied.
            machine.succeed("test -z \"$(printf unavailable | ip netns exec alpha ${lib.getExe pkgs.netcat} -N -w 1 10.100.0.1 5037)\"")
            machine.succeed("systemd-run --unit=seter-test-host-daemon --property=Type=simple -- ${lib.getExe pkgs.socat} TCP4-LISTEN:15037,bind=127.0.0.1,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat")
            machine.wait_for_unit("seter-test-host-daemon.service")
            machine.succeed("test \"$(printf gateway-ok | ip netns exec alpha ${lib.getExe pkgs.netcat} -N -w 2 10.100.0.1 5037)\" = gateway-ok")
            machine.fail("ip netns exec beta ${lib.getExe pkgs.netcat} -z -w 1 10.100.0.1 5037")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 10.100.0.1 15037")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 10.100.0.1 5038")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 11.0.0.2 5037")
            machine.succeed("test $(nft --json list chain inet seter_l3 input | jq '[.nftables[].rule | select(.comment == \"seter host service alpha adb\") | .expr[].counter.packets?] | add // 0') -gt 0")
            machine.succeed("main=$(systemctl show --value --property MainPID seter-gateway-adb.service); test \"$main\" -gt 1; test $(awk '/^Uid:/ { print $2 }' /proc/$main/status) != 0")

            # An unregistered, non-isolated bridge port must not create a
            # layer-2 escape path from a registered workspace.
            machine.succeed("ip netns add bridge-peer; ip link add peer-host type veth peer name eth0 netns bridge-peer")
            machine.succeed("ip link set peer-host master seter0; ip link set peer-host up")
            machine.succeed("ip -n bridge-peer link set lo up; ip -n bridge-peer link set eth0 up; ip -n bridge-peer address add 10.100.0.12/24 dev eth0")
            machine.fail("ip netns exec bridge-peer ping -c 1 -W 1 10.100.0.1")

            # Enabling kernel forwarding for Seter must not turn the host into
            # a router between unrelated interfaces.
            machine.succeed("ip netns add unrelated-a; ip link add u-a-host type veth peer name eth0 netns unrelated-a")
            machine.succeed("ip address add 172.16.1.1/24 dev u-a-host; ip link set u-a-host up; ip -n unrelated-a link set lo up; ip -n unrelated-a link set eth0 up; ip -n unrelated-a address add 172.16.1.2/24 dev eth0; ip -n unrelated-a route add default via 172.16.1.1")
            machine.succeed("ip netns add unrelated-b; ip link add u-b-host type veth peer name eth0 netns unrelated-b")
            machine.succeed("ip address add 172.16.2.1/24 dev u-b-host; ip link set u-b-host up; ip -n unrelated-b link set lo up; ip -n unrelated-b link set eth0 up; ip -n unrelated-b address add 172.16.2.2/24 dev eth0; ip -n unrelated-b route add default via 172.16.2.1")
            machine.fail("ip netns exec unrelated-a ping -c 1 -W 1 172.16.2.2")

            # A routed outside namespace proves that the default deny is not
            # merely an accidental consequence of forwarding being disabled.
            machine.succeed("ip netns add outside; ip link add outside-host type veth peer name eth0 netns outside")
            machine.succeed("ip address add 11.0.0.1/24 dev outside-host; ip link set outside-host up")
            machine.succeed("ip -n outside link set lo up; ip -n outside link set eth0 up; ip -n outside address add 11.0.0.2/24 dev eth0; ip -n outside route add 10.100.0.0/24 via 11.0.0.1")
            machine.succeed("systemd-run --unit=seter-test-upstream --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --user=root --port=53 --listen-address=11.0.0.2 --bind-interfaces --no-resolv --no-hosts --address=/allowed.example/11.0.0.2 --address=/bad-cert.example/11.0.0.2 --address=/direct.example/11.0.0.2 --address=/multicast.example/224.0.0.1 --address=/passthrough.example/11.0.0.2 --address=/rebind.example/10.0.0.2 --address=/second-allowed.example/11.0.0.2")
            machine.wait_for_unit("seter-test-upstream.service")
            machine.succeed("systemd-run --unit=seter-test-direct-tcp --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${lib.getExe pkgs.socat} TCP4-LISTEN:2222,bind=11.0.0.2,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat")
            machine.wait_for_unit("seter-test-direct-tcp.service")
            machine.succeed("systemd-run --unit=seter-test-denied-tcp --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${lib.getExe pkgs.socat} TCP4-LISTEN:2223,bind=11.0.0.2,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/true")
            machine.wait_for_unit("seter-test-denied-tcp.service")
            machine.succeed("systemctl start seter-tcp-egress-alpha.service")
            machine.wait_for_unit("seter-tcp-egress-alpha.service")
            machine.succeed("nft get element inet seter_l3 ${alphaTcpSet} '{ 11.0.0.2 . 2222 }'")
            machine.fail("nft get element inet seter_l3 ${alphaTcpSet} '{ 10.0.0.2 . 2224 }'")
            machine.fail("nft get element inet seter_l3 ${alphaTcpSet} '{ 224.0.0.1 . 2225 }'")
            machine.succeed("mkdir -p /tmp/seter-upstream; printf 'allowed upstream\\n' > /tmp/seter-upstream/index.html")
            machine.succeed("systemd-run --unit=seter-test-http --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${pkgs.python3}/bin/python ${proxyHttpServer}")
            machine.wait_for_unit("seter-test-http.service")
            machine.succeed("systemd-run --unit=seter-test-https --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${pkgs.python3}/bin/python ${proxyHttpServer} 443 ${proxyTestCertificate}/cert.pem ${proxyTestCertificate}/key.pem")
            machine.wait_for_unit("seter-test-https.service")

            # Workspaces can query the host resolver over UDP and TCP. Only
            # configured egress-name suffixes are forwarded, and IPv6 answers
            # remain hidden while Seter's network boundary is IPv4-only.
            machine.succeed("test $(ip netns exec alpha dig +short @10.100.0.1 allowed.example A) = 11.0.0.2")
            machine.succeed("test $(ip netns exec alpha dig +tcp +short @10.100.0.1 allowed.example A) = 11.0.0.2")
            machine.succeed("test $(ip netns exec alpha dig +short @10.100.0.1 child.allowed.example A) = 11.0.0.2")
            machine.succeed("ip netns exec alpha dig @10.100.0.1 denied.example A | grep -F 'status: NXDOMAIN'")
            machine.succeed("ip netns exec beta dig @10.100.0.1 allowed.example A | grep -F 'status: NXDOMAIN'")
            machine.fail("ip netns exec beta dig +time=1 +tries=1 -p ${toString alphaDnsPort} @10.100.0.1 allowed.example A")
            machine.succeed("alpha_pid=$(systemctl show --value --property MainPID seter-dns-alpha.service); beta_pid=$(systemctl show --value --property MainPID seter-dns-beta.service); test $(awk '/^Uid:/ { print $2 }' /proc/$alpha_pid/status) != $(awk '/^Uid:/ { print $2 }' /proc/$beta_pid/status)")
            machine.succeed("test -z \"$(ip netns exec alpha dig +short @10.100.0.1 allowed.example AAAA)\"")
            machine.succeed("journalctl -u seter-dns-alpha.service | grep -F 'query[A] allowed.example from 10.100.0.10'")
            machine.succeed("getent ahostsv4 alpha.vm | grep -F '10.100.0.10'")
            machine.fail("ip netns exec alpha dig +time=1 +tries=1 @11.0.0.2 allowed.example A")

            # Direct TCP policy is keyed by workspace source, the currently
            # resolved public IPv4 addresses, and destination port. Routed
            # packets are masqueraded, while another workspace, another port,
            # and a private DNS-rebinding answer remain denied.
            machine.succeed("test $(ip netns exec alpha dig +short @10.100.0.1 direct.example A) = 11.0.0.2")
            machine.succeed("nft reset counters table ip seter_tcp_nat")
            machine.succeed("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 2 11.0.0.2 2222")
            machine.succeed("test $(nft --json list chain ip seter_tcp_nat postrouting | jq '[.nftables[].rule | select(.comment == \"seter direct TCP egress\") | .expr[].counter.packets?] | add // 0') -gt 0")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 11.0.0.2 2223")
            machine.fail("ip netns exec beta ${lib.getExe pkgs.netcat} -z -w 1 11.0.0.2 2222")
            machine.succeed("test -z \"$(ip netns exec alpha dig +short @10.100.0.1 rebind.example A)\"")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 10.0.0.2 2224")
            machine.fail("nft get element inet seter_l3 ${alphaTcpSet} '{ 224.0.0.1 . 2225 }'")

            # Revoking a set element must also stop an already-established
            # connection rather than preserving it through conntrack state.
            machine.succeed("systemd-run --unit=seter-test-direct-client --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec alpha ${pkgs.python3}/bin/python ${directTcpClient}")
            machine.wait_until_succeeds("test -e /tmp/seter-direct-client-ready")
            machine.succeed("nft delete element inet seter_l3 ${alphaTcpSet} '{ 11.0.0.2 . 2222 }'; touch /tmp/seter-direct-client-send")
            machine.wait_until_succeeds("test -e /tmp/seter-direct-client-blocked")
            machine.fail("test -e /tmp/seter-direct-client-allowed")
            machine.succeed("systemctl reload seter-tcp-egress-alpha.service")
            machine.succeed("nft get element inet seter_l3 ${alphaTcpSet} '{ 11.0.0.2 . 2222 }'")

            # Ports 80 and 443 are transparently redirected. The proxy uses
            # the registered source address to apply an exact host allowlist,
            # returns a useful 403 on denials, and resolves the reviewed host
            # instead of trusting the packet's original destination.
            machine.succeed("ip netns exec alpha curl --noproxy '*' --fail --silent http://allowed.example/ | grep -F 'allowed upstream'")
            machine.succeed("ip netns exec alpha curl --proxy http://10.100.0.1:${toString explicitProxyPort} --fail --silent http://allowed.example/ | grep -F 'allowed upstream'")
            machine.succeed("test $(ip netns exec alpha curl --proxy http://10.100.0.1:${toString explicitProxyPort} --silent --output /tmp/explicit-denied --write-out '%{http_code}' http://denied.example/) = 403; grep -F 'not in this workspace' /tmp/explicit-denied")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --fail --silent http://allowed.example/ http://allowed.example/index.html | grep -c 'allowed upstream') = 2")
            machine.succeed("ip netns exec alpha curl --noproxy '*' --fail --silent -H 'Host: allowed.example' http://11.0.0.1/ | grep -F 'allowed upstream'")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/denied --write-out '%{http_code}' -H 'Host: denied.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/denied")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/child-denied --write-out '%{http_code}' -H 'Host: child.allowed.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/child-denied")
            machine.succeed("test $(ip netns exec beta curl --noproxy '*' --silent --output /tmp/beta-denied --write-out '%{http_code}' -H 'Host: allowed.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/beta-denied")
            machine.succeed("ip netns exec alpha curl --noproxy '*' --insecure --fail --silent https://allowed.example/index.html | grep -F 'allowed upstream'")
            machine.succeed("ip netns exec alpha curl --proxy http://10.100.0.1:${toString explicitProxyPort} --cacert /var/lib/seter-proxy-public/seter-proxy-ca-cert.pem --fail --silent https://allowed.example/index.html | grep -F 'allowed upstream'")
            # Header placeholders are replaced from the workspace's private
            # runtime credential only after exact host and HTTPS approval.
            # Both transparent and explicit proxy paths reach the same request
            # hook, while cleartext and another otherwise-allowed host fail
            # closed without exposing the credential.
            # The upstream records the injected value out of band. Exact
            # reflections in response headers and compressed or plain bodies
            # are restored to the harmless placeholder before reaching the
            # workspace.
            machine.succeed("rm -f /tmp/seter-secret-received /tmp/secret-body /tmp/secret-headers; ip netns exec alpha curl --noproxy '*' --insecure --fail --silent --dump-header /tmp/secret-headers --output /tmp/secret-body -H 'Authorization: Bearer seter-placeholder-0123456789abcdef' https://allowed.example/secret")
            machine.succeed("grep -Fx 'Bearer rotated-runtime-token' /tmp/seter-secret-received; grep -Fx 'Bearer seter-placeholder-0123456789abcdef' /tmp/secret-body; grep -Fi 'X-Reflected-Authorization: Bearer seter-placeholder-0123456789abcdef' /tmp/secret-headers")
            machine.fail("grep -F rotated-runtime-token /tmp/secret-body /tmp/secret-headers")
            machine.succeed("rm -f /tmp/seter-secret-received /tmp/secret-body /tmp/secret-headers; ip netns exec alpha curl --proxy http://10.100.0.1:${toString explicitProxyPort} --cacert /var/lib/seter-proxy-public/seter-proxy-ca-cert.pem --fail --silent --compressed --dump-header /tmp/secret-headers --output /tmp/secret-body -H 'Authorization: token seter-placeholder-0123456789abcdef' https://allowed.example/secret-gzip")
            machine.succeed("grep -Fx 'token rotated-runtime-token' /tmp/seter-secret-received; grep -Fx 'token seter-placeholder-0123456789abcdef' /tmp/secret-body; grep -Fi 'X-Reflected-Authorization: token seter-placeholder-0123456789abcdef' /tmp/secret-headers")
            machine.fail("grep -F rotated-runtime-token /tmp/secret-body /tmp/secret-headers")

            # Multiple recognized placeholders are validated atomically. A
            # wrong-host binding denies the whole request before either value
            # is sent. A different workspace can use the same public text but
            # receives no credential it does not own.
            machine.succeed("rm -f /tmp/seter-secret-received; test $(ip netns exec alpha curl --noproxy '*' --insecure --silent --output /tmp/secret-atomic-denied --write-out '%{http_code}' -H 'Authorization: Bearer seter-placeholder-0123456789abcdef' -H 'X-Api-Key: seter-placeholder-fedcba9876543210' https://allowed.example/secret) = 403; grep -F 'not bound to host' /tmp/secret-atomic-denied; test ! -e /tmp/seter-secret-received")
            machine.succeed("rm -f /tmp/seter-secret-received; ip netns exec beta curl --noproxy '*' --insecure --fail --silent -H 'Authorization: Bearer seter-placeholder-0123456789abcdef' https://second-allowed.example/secret | grep -Fx 'Bearer seter-placeholder-0123456789abcdef'; grep -Fx 'Bearer seter-placeholder-0123456789abcdef' /tmp/seter-secret-received")
            machine.succeed("rm -f /tmp/seter-secret-received; test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/secret-http-denied --write-out '%{http_code}' -H 'Authorization: Bearer seter-placeholder-0123456789abcdef' http://allowed.example/secret) = 403; grep -F 'only be injected over HTTPS' /tmp/secret-http-denied; test ! -e /tmp/seter-secret-received")
            machine.succeed("rm -f /tmp/seter-secret-received; test $(ip netns exec alpha curl --noproxy '*' --insecure --silent --output /tmp/secret-host-denied --write-out '%{http_code}' -H 'Authorization: Bearer seter-placeholder-0123456789abcdef' https://second-allowed.example/secret) = 403; grep -F 'not bound to host' /tmp/secret-host-denied; test ! -e /tmp/seter-secret-received")

            # Replacement is deliberately header-only. The same placeholder
            # in a query string and request body remains harmless public text,
            # even when another occurrence is injected in an approved header.
            machine.succeed("rm -f /tmp/seter-secret-received /tmp/secret-body; ip netns exec alpha curl --noproxy '*' --insecure --fail --silent --output /tmp/secret-body -H 'Authorization: Bearer seter-placeholder-0123456789abcdef' --data-binary 'body=seter-placeholder-0123456789abcdef' 'https://allowed.example/secret?query=seter-placeholder-0123456789abcdef'")
            machine.succeed("grep -Fx 'Bearer rotated-runtime-token' /tmp/seter-secret-received; grep -Fx '/secret?query=seter-placeholder-0123456789abcdef' /tmp/seter-secret-received; grep -Fx 'body=seter-placeholder-0123456789abcdef' /tmp/seter-secret-received; grep -Fx 'Bearer seter-placeholder-0123456789abcdef' /tmp/secret-body; grep -Fx '/secret?query=seter-placeholder-0123456789abcdef' /tmp/secret-body; grep -Fx 'body=seter-placeholder-0123456789abcdef' /tmp/secret-body; ! grep -F rotated-runtime-token /tmp/secret-body")

            # Ordinary header values pass through unchanged. Conversely, an
            # approved binding does not weaken upstream certificate checks:
            # a hostname/certificate mismatch must fail before the server can
            # observe the already-rewritten request object.
            machine.succeed("rm -f /tmp/seter-secret-received; ip netns exec alpha curl --noproxy '*' --insecure --fail --silent -H 'Authorization: Bearer ordinary-public-value' https://allowed.example/secret | grep -Fx 'Bearer ordinary-public-value'; grep -Fx 'Bearer ordinary-public-value' /tmp/seter-secret-received")
            machine.succeed("rm -f /tmp/seter-secret-received /tmp/seter-bad-cert-tls-seen; ! ip netns exec alpha curl --noproxy '*' --insecure --fail --silent -H 'Authorization: Bearer seter-placeholder-0123456789abcdef' https://bad-cert.example/secret; test -e /tmp/seter-bad-cert-tls-seen; test ! -e /tmp/seter-secret-received")
            machine.succeed("rm -f /tmp/seter-secret-received; ip netns exec alpha curl --noproxy '*' --insecure --fail --silent -H 'X-Unconfigured: seter-placeholder-0123456789abcdef' https://allowed.example/secret | grep -Fx 'seter-placeholder-0123456789abcdef'; grep -Fx 'seter-placeholder-0123456789abcdef' /tmp/seter-secret-received")
            machine.succeed("journalctl -u seter-proxy.service | grep -F 'seter-audit' | grep -F '\"injectedSecrets\":[\"githubToken\"]'")
            machine.succeed("journalctl -u seter-proxy.service | grep -F 'seter-audit' | grep -F '\"event\":\"response-redaction\"' | grep -F '\"redactedSecrets\":[\"githubToken\"]'")
            machine.fail("journalctl -u seter-proxy.service | grep -F rotated-runtime-token")
            machine.succeed("printf 'CONNECT allowed.example:22 HTTP/1.1\\r\\nHost: allowed.example:22\\r\\n\\r\\n' | ip netns exec alpha ${lib.getExe pkgs.netcat} -w 2 10.100.0.1 ${toString explicitProxyPort} | grep -F '403'")
            machine.succeed("ip netns exec alpha curl --noproxy '*' --insecure --fail --silent --resolve allowed.example:443:11.0.0.1 https://allowed.example/index.html | grep -F 'allowed upstream'")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --insecure --silent --output /tmp/https-denied --write-out '%{http_code}' --resolve denied.example:443:11.0.0.2 https://denied.example/) = 403; grep -F 'not in this workspace' /tmp/https-denied")
            machine.succeed("ip netns exec alpha ${lib.getExe pkgs.openssl} s_client -connect 11.0.0.2:443 -noservername </dev/null >/dev/null 2>&1 || true; journalctl -u seter-proxy.service | grep -F 'seter-audit' | grep -F '\"host\":\"\"' | grep -F 'missing'")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --insecure --silent --output /tmp/sni-host-mismatch --write-out '%{http_code}' -H 'Host: second-allowed.example' https://allowed.example/) = 403; grep -F 'SNI and HTTP host do not match' /tmp/sni-host-mismatch")
            machine.fail("ip netns exec alpha curl --noproxy '*' --insecure --fail --silent https://bad-cert.example/")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/private-denied --write-out '%{http_code}' -H 'Host: private.example' http://11.0.0.2/) = 403; grep -F 'did not resolve to a public IPv4 address' /tmp/private-denied")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/multicast-denied --write-out '%{http_code}' -H 'Host: multicast.example' http://11.0.0.2/) = 403; grep -F 'did not resolve to a public IPv4 address' /tmp/multicast-denied")

            # Private-address denial is also enforced on the proxy account's
            # output packets, independently of the Python policy addon.
            machine.succeed("systemd-run --unit=seter-test-private-http --property=Type=simple -- ${lib.getExe pkgs.socat} TCP4-LISTEN:18081,bind=127.0.0.1,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/true")
            machine.wait_for_unit("seter-test-private-http.service")
            machine.succeed("${lib.getExe pkgs.netcat} -z -w 1 127.0.0.1 18081")
            machine.fail("${pkgs.util-linux}/bin/runuser -u seter-proxy -- ${lib.getExe pkgs.netcat} -z -w 1 127.0.0.1 18081")

            # Passthrough policy is selected solely from the TLS SNI. The
            # upstream certificate reaches the client unchanged, while the
            # proxy still discards the packet destination and resolves the
            # reviewed SNI itself. Passthrough names are HTTPS-only and remain
            # isolated between workspaces.
            machine.succeed("ip netns exec alpha curl --noproxy '*' --cacert ${proxyTestCertificate}/cert.pem --fail --silent https://passthrough.example/index.html | grep -F 'allowed upstream'")
            machine.succeed("ip netns exec alpha curl --proxy http://10.100.0.1:${toString explicitProxyPort} --cacert ${proxyTestCertificate}/cert.pem --fail --silent https://passthrough.example/index.html | grep -F 'allowed upstream'")
            machine.succeed("ip netns exec alpha curl --noproxy '*' --cacert ${proxyTestCertificate}/cert.pem --fail --silent --resolve passthrough.example:443:11.0.0.1 https://passthrough.example/index.html | grep -F 'allowed upstream'")
            machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/passthrough-http-denied --write-out '%{http_code}' -H 'Host: passthrough.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/passthrough-http-denied")
            machine.succeed("test $(ip netns exec beta curl --noproxy '*' --insecure --silent --output /tmp/passthrough-beta-denied --write-out '%{http_code}' --resolve passthrough.example:443:11.0.0.2 https://passthrough.example/) = 403; grep -F 'not in this workspace' /tmp/passthrough-beta-denied")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 10.100.0.1 ${toString proxyPort}")
            machine.succeed("journalctl -u seter-proxy.service | grep -F 'seter-audit' | grep -F '\"workspace\":\"alpha\"' | grep -F '\"decision\":\"allow\"'")
            machine.succeed("journalctl -u seter-proxy.service | grep -F 'seter-audit' | grep -F '\"workspace\":\"beta\"' | grep -F '\"decision\":\"deny\"'")
            machine.succeed("journalctl -u seter-proxy.service | grep -F 'seter-audit' | grep -F '\"protocol\":\"tls-passthrough\"' | grep -F '\"host\":\"passthrough.example\"'")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.openssl} s_client -connect 11.0.0.2:443 -servername private-passthrough.example -verify_return_error -CAfile ${proxyTestCertificate}/cert.pem </dev/null")
            machine.succeed("journalctl -u seter-proxy.service | grep -F 'seter-audit' | grep -F '\"decision\":\"deny\"' | grep -F '\"host\":\"private-passthrough.example\"' | grep -F 'did not resolve to a public IPv4 address'")

            # Opening the internal DNS port in the host firewall must not make
            # an unrelated service on another host-local address reachable.
            machine.succeed("systemd-run --unit=seter-test-host-port --property=Type=simple -- ${lib.getExe pkgs.socat} TCP4-LISTEN:${toString alphaDnsPort},bind=11.0.0.1,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/true")
            machine.wait_for_unit("seter-test-host-port.service")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 11.0.0.1 ${toString alphaDnsPort}")

            # A host nftables reload, including a complete ruleset flush, must
            # atomically recreate the Seter tables while workspaces are live.
            machine.succeed("systemctl reload nftables.service")
            machine.succeed("nft list table bridge seter_l2")
            machine.succeed("nft list table inet seter_l3")
            machine.succeed("nft list table inet seter_dns")
            machine.succeed("nft list table inet seter_proxy")
            machine.succeed("nft list table inet seter_proxy_output")
            machine.succeed("nft list table ip seter_tcp_nat")
            machine.wait_until_succeeds("nft get element inet seter_l3 ${alphaTcpSet} '{ 11.0.0.2 . 2222 }'")
            machine.succeed("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 2 11.0.0.2 2222")
            machine.succeed("test \"$(printf after-reload | ip netns exec alpha ${lib.getExe pkgs.netcat} -N -w 2 10.100.0.1 5037)\" = after-reload")

            # Keep a relay flow established while switching authorization to
            # beta. The authorization restart trigger must close alpha's old
            # flow as well as reject new ones; beta must retain service.
            machine.succeed("systemd-run --unit=seter-test-alpha-gateway-connection --property=Type=simple -- ip netns exec alpha ${lib.getExe pkgs.socat} TCP4:10.100.0.1:5037 EXEC:${pkgs.coreutils}/bin/cat")
            machine.wait_until_succeeds("ip netns exec alpha ${pkgs.iproute2}/bin/ss -Htn state established | grep -Fq '10.100.0.1:5037'")
            machine.succeed("/run/current-system/specialisation/gateway-revoked/bin/switch-to-configuration test")
            machine.wait_until_fails("ip netns exec alpha ${pkgs.iproute2}/bin/ss -Htn state established | grep -Fq '10.100.0.1:5037'")
            machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 10.100.0.1 5037")
            machine.succeed("systemctl start seter-test-gateway-consumer.service")
            machine.wait_for_unit("seter-gateway-adb.socket")
            machine.succeed("test \"$(printf beta-authorized | ip netns exec beta ${lib.getExe pkgs.netcat} -N -w 2 10.100.0.1 5037)\" = beta-authorized")

            # Releasing the final consumer lets the idle proxyd exit and the
            # shared socket stop. Restart it afterwards so the nftables-stop
            # dependency test below still exercises an active listener.
            machine.succeed("systemctl stop seter-test-gateway-consumer.service")
            machine.wait_until_fails("systemctl is-active --quiet seter-gateway-adb.service")
            machine.wait_until_fails("systemctl is-active --quiet seter-gateway-adb.socket")
            machine.succeed("systemctl start seter-test-gateway-consumer.service")
            machine.wait_for_unit("seter-gateway-adb.socket")

            # The host may initiate connections to a workspace. A workspace
            # may not initiate connections to the host, its peers, or routed
            # networks.
            machine.succeed("ping -c 1 -W 1 10.100.0.10")
            machine.succeed("ping -c 1 -W 1 10.100.0.11")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.1")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.11")
            # nftables remains a second lateral boundary if bridge-port
            # isolation is accidentally removed at runtime.
            machine.succeed("bridge link set dev seter-alpha isolated off; bridge link set dev seter-beta isolated off; nft reset counters table bridge seter_l2")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.11")
            machine.succeed("test $(nft --json list chain bridge seter_l2 forward | jq '[.nftables[].rule | select(.comment == \"seter lateral isolation alpha\") | .expr[].counter.packets?] | add // 0') -gt 0; bridge link set dev seter-alpha isolated on; bridge link set dev seter-beta isolated on")

            # The blanket bridge-forward rule also rejects non-workspace ports.
            machine.succeed("nft reset counters table bridge seter_l2")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.12")
            machine.succeed("test $(nft --json list chain bridge seter_l2 forward | jq '[.nftables[].rule | select(.comment == \"seter lateral isolation alpha\") | .expr[].counter.packets?] | add // 0') -gt 0")

            machine.succeed("nft reset counters table inet seter_l3")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 11.0.0.2")
            machine.succeed("test $(nft --json list chain inet seter_l3 forward | jq '[.nftables[].rule | select(.comment == \"seter default-deny alpha\") | .expr[].counter.packets?] | add // 0') -gt 0")

            # Registered IPv4/ARP packets pass the bridge identity chain and
            # are denied later by the host-input chain.
            machine.succeed("nft reset counters table inet seter_l3")
            machine.fail("ip netns exec alpha ping -c 1 -W 1 10.100.0.1")
            machine.succeed("test $(nft --json list chain inet seter_l3 input | jq '[.nftables[].rule | select(.comment == \"seter host isolation alpha\") | .expr[].counter.packets?] | add // 0') -gt 0")

            # A forged IPv4 source is rejected even when ARP is bypassed with a
            # permanent neighbor entry.
            machine.succeed("ip -n alpha address add 10.100.0.99/24 dev eth0; gateway_mac=$(cat /sys/class/net/seter0/address); ip -n alpha neighbor replace 10.100.0.1 lladdr $gateway_mac dev eth0 nud permanent")
            machine.succeed("before=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); ip netns exec alpha ping -c 1 -W 1 -I 10.100.0.99 10.100.0.1 || true; after=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); test \"$after\" -gt \"$before\"")

            # Forged ARP sender identities are rejected independently.
            machine.succeed("ip -n alpha neighbor del 10.100.0.1 dev eth0; before=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); ip netns exec alpha arping -c 1 -w 1 -s 10.100.0.99 -I eth0 10.100.0.1 || true; after=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); test \"$after\" -gt \"$before\"")
            machine.succeed("ip -n alpha address del 10.100.0.99/24 dev eth0")

            # The guest cannot adopt another MAC address either.
            machine.succeed("ip -n alpha link set eth0 down; ip -n alpha link set eth0 address 02:00:00:00:00:99; ip -n alpha link set eth0 up")
            machine.succeed("before=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); ip netns exec alpha ping -c 1 -W 1 10.100.0.1 || true; after=$(nft --json list chain bridge seter_l2 ingress | jq '[.nftables[].rule | select(.comment == \"seter anti-spoof alpha\") | .expr[].counter.packets?] | add // 0'); test \"$after\" -gt \"$before\"")
            machine.succeed("ip -n alpha link set eth0 down; ip -n alpha link set eth0 address 02:00:00:00:00:10; ip -n alpha link set eth0 up")

            # IPv6 is closed until Seter has an explicit IPv6 policy.
            machine.succeed("ip -6 address add fd00::1/64 dev seter0; ip -n alpha -6 address add fd00::10/64 dev eth0")
            machine.fail("ip netns exec alpha ping -6 -c 1 -W 1 fd00::1")

            machine.succeed("ip netns del alpha; ip netns del beta; ip netns del bridge-peer; ip netns del outside; ip netns del unrelated-a; ip netns del unrelated-b; ip link del seter-alpha 2>/dev/null || true; ip link del seter-beta 2>/dev/null || true")

            # Stopping the required nftables backend tears down active
            # workspace plumbing before its policy tables are removed.
            machine.succeed("systemctl start seter-runtime-alpha.target")
            machine.succeed("ip link show dev seter-alpha")
            machine.succeed("systemctl stop nftables.service")
            machine.wait_until_fails("ip link show dev seter-alpha")
            machine.wait_until_fails("systemctl is-active --quiet seter-gateway-adb.socket")
            machine.fail("nft list table bridge seter_l2")
            machine.fail("nft list table inet seter_l3")
            machine.fail("nft list table inet seter_proxy")
            machine.fail("nft list table inet seter_proxy_output")
            machine.fail("nft list table ip seter_tcp_nat")

            # If the nftables policy cannot load, its dependency prevents a
            # registered TAP from being created.
            machine.succeed("mkdir -p /run/systemd/system/nftables.service.d; printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/false\\n' > /run/systemd/system/nftables.service.d/fail.conf; systemctl daemon-reload")
            machine.fail("systemctl start seter-runtime-alpha.target")
            machine.fail("ip link show dev seter-alpha")
            machine.fail("systemctl is-active --quiet seter-dns-alpha.service")
            machine.fail("systemctl is-active --quiet seter-tcp-egress-alpha.service")
            machine.fail("systemctl is-active --quiet seter-proxy.service")
            machine.succeed("rm -rf /run/systemd/system/nftables.service.d; systemctl daemon-reload; systemctl reset-failed nftables.service seter-dns-alpha.service seter-tcp-egress-alpha.service seter-proxy.service seter-tap-alpha.service seter-virtiofsd-alpha.service seter-runtime-alpha.target")

            # A proxy startup failure must also keep the workspace TAP absent.
            machine.succeed("systemctl start nftables.service; mkdir -p /run/systemd/system/seter-proxy.service.d; printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/false\\n' > /run/systemd/system/seter-proxy.service.d/fail.conf; systemctl daemon-reload")
            machine.fail("systemctl start seter-runtime-alpha.target")
            machine.fail("ip link show dev seter-alpha")
            machine.succeed("rm -rf /run/systemd/system/seter-proxy.service.d; systemctl daemon-reload; systemctl reset-failed seter-proxy.service seter-tap-alpha.service seter-virtiofsd-alpha.service seter-runtime-alpha.target")
          '';
        };
      };
    };
}
