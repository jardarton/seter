{
  self,
  pkgs,
  validWorkspaces,
}:
let
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

  directTcpClient = ./helpers/direct-tcp-client.py;

  dnsTestPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.dnspython ]);
  dnsAdversarialClient = ./helpers/dns-adversarial-client.py;

  udpRecorder = ./helpers/udp-recorder.py;

  lib = pkgs.lib;
  proxyHttpServer = ./helpers/proxy-test-http-server.py;
  alphaDnsPort =
    (import ../nix/modules/host/dns-ports.nix {
      inherit lib;
      workspaces = validWorkspaces;
    }).alpha;
  alphaTcpSet =
    (import ../nix/modules/host/tcp-egress-sets.nix {
      inherit lib;
      workspaces = validWorkspaces;
    }).alpha;
in
pkgs.testers.runNixOSTest {
  name = "seter-network-isolation";

  nodes.machine = {
    imports = [ self.nixosModules.host ];

    environment.systemPackages = [
      pkgs.bind
      pkgs.curl
      pkgs.dnsmasq
      dnsTestPython
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
      "api.wild.example"
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
      policyFile = ./fixtures/network-isolation-policy.toml;
      gatewayServices.adb = {
        listenPort = 5037;
        targetPort = 15037;
      };
      workspaces = validWorkspaces // {
        alpha = validWorkspaces.alpha // {
          hostServices = [ "adb" ];
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
        # Beta's Policy File grants HTTP without a credential binding.
        beta = validWorkspaces.beta;
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

  testScript =
    { nodes, ... }:
    let
      config = nodes.machine;
    in
    ''
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
      machine.wait_until_fails("systemctl is-active --quiet seter-gateway-adb.service")
      machine.succeed("systemd-run --unit=seter-test-host-daemon --property=Type=simple -- ${lib.getExe pkgs.socat} TCP4-LISTEN:15037,bind=127.0.0.1,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat")
      machine.wait_for_unit("seter-test-host-daemon.service")
      machine.wait_until_succeeds("ss -H -ltn 'sport = :15037' | grep -q 127.0.0.1:15037")
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
      machine.succeed("systemd-run --unit=seter-test-upstream --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --user=root --port=53 --listen-address=11.0.0.2 --bind-interfaces --no-resolv --no-hosts --log-queries --log-facility=- --address=/allowed.example/11.0.0.2 --address=/api.wild.example/11.0.0.2 --address=/bad-cert.example/11.0.0.2 --address=/direct.example/11.0.0.2 --address=/multicast.example/224.0.0.1 --address=/passthrough.example/11.0.0.2 --address=/rebind.example/10.0.0.2 --address=/second-allowed.example/11.0.0.2")
      machine.wait_for_unit("seter-test-upstream.service")
      machine.succeed("systemd-run --unit=seter-test-direct-tcp --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${lib.getExe pkgs.socat} TCP4-LISTEN:2222,bind=11.0.0.2,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/cat")
      machine.wait_for_unit("seter-test-direct-tcp.service")
      machine.succeed("systemd-run --unit=seter-test-denied-tcp --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${lib.getExe pkgs.socat} TCP4-LISTEN:2223,bind=11.0.0.2,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/true")
      machine.wait_for_unit("seter-test-denied-tcp.service")
      machine.succeed("systemd-run --unit=seter-test-quic-udp --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${pkgs.python3}/bin/python ${udpRecorder} 11.0.0.2 443 /tmp/seter-quic-udp-received")
      machine.wait_for_unit("seter-test-quic-udp.service")
      machine.succeed("systemd-run --unit=seter-test-generic-udp --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${pkgs.python3}/bin/python ${udpRecorder} 11.0.0.2 4444 /tmp/seter-generic-udp-received")
      machine.wait_for_unit("seter-test-generic-udp.service")
      machine.succeed("systemd-run --unit=seter-test-dot --property=Type=simple -- ${pkgs.iproute2}/bin/ip netns exec outside ${lib.getExe pkgs.socat} TCP4-LISTEN:853,bind=11.0.0.2,reuseaddr,fork EXEC:${pkgs.coreutils}/bin/true")
      machine.wait_for_unit("seter-test-dot.service")
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

      # Workspaces can query the host resolver over UDP and TCP. The
      # frontend accepts only exact configured names, rebuilds permitted
      # A requests before forwarding, and answers AAAA locally while the
      # network boundary remains IPv4-only.
      machine.succeed("test $(ip netns exec alpha dig +short @10.100.0.1 allowed.example A) = 11.0.0.2")
      machine.succeed("test $(ip netns exec alpha dig +tcp +short @10.100.0.1 allowed.example A) = 11.0.0.2")
      machine.succeed("test $(ip netns exec alpha dig +short @10.100.0.1 api.wild.example A) = 11.0.0.2")
      machine.succeed("ip netns exec alpha dig @10.100.0.1 wild.example A | grep -F 'status: REFUSED'")
      machine.succeed("ip netns exec alpha dig @10.100.0.1 deep.api.wild.example A | grep -F 'status: REFUSED'")
      machine.succeed("ip netns exec alpha dig @10.100.0.1 child.allowed.example A | grep -F 'status: REFUSED'")
      machine.succeed("ip netns exec alpha dig @10.100.0.1 denied.example A | grep -F 'status: REFUSED'")
      machine.succeed("ip netns exec beta dig @10.100.0.1 allowed.example A | grep -F 'status: REFUSED'")
      machine.fail("ip netns exec beta dig +time=1 +tries=1 -p ${toString alphaDnsPort} @10.100.0.1 allowed.example A")
      machine.succeed("alpha_pid=$(systemctl show --value --property MainPID seter-dns-alpha.service); beta_pid=$(systemctl show --value --property MainPID seter-dns-beta.service); test $(awk '/^Uid:/ { print $2 }' /proc/$alpha_pid/status) != $(awk '/^Uid:/ { print $2 }' /proc/$beta_pid/status)")
      machine.succeed("test -z \"$(ip netns exec alpha dig +short @10.100.0.1 allowed.example AAAA)\"")
      machine.succeed("ip netns exec alpha ${dnsTestPython}/bin/python ${dnsAdversarialClient} 10.100.0.1")
      machine.succeed("journalctl -u seter-dns-alpha.service | grep -F 'seter-dns-audit' | grep -F '\"decision\":\"allow\"' | grep -F '\"name\":\"allowed.example\"' | grep -F '\"type\":\"A\"'")
      machine.succeed("journalctl -u seter-dns-alpha.service | grep -F 'seter-dns-audit' | grep -F '\"decision\":\"deny\"' | grep -F '\"name\":\"child.allowed.example\"' | grep -F 'not exactly allowlisted'")
      machine.succeed("journalctl -u seter-dns-alpha.service | grep -F 'seter-dns-audit' | grep -F 'exactly one DNS question is required'")
      machine.fail("journalctl -u seter-test-upstream.service | grep -Fi 'child.allowed.example'")
      machine.fail("journalctl -u seter-test-upstream.service | grep -Fi 'must-not-be-forwarded'")
      machine.succeed("getent ahostsv4 alpha.vm | grep -F '10.100.0.10'")
      machine.fail("ip netns exec alpha dig +time=1 +tries=1 @11.0.0.2 allowed.example A")
      machine.fail("ip netns exec alpha dig +tcp +time=1 +tries=1 @11.0.0.2 allowed.example A")

      # DNS is the only permitted UDP protocol. QUIC cannot bypass the
      # TCP HTTP policy, arbitrary UDP remains closed, and DNS-over-TLS
      # is unavailable unless its endpoint is separately authorized as
      # direct TCP.
      machine.succeed("rm -f /tmp/seter-quic-udp-received /tmp/seter-generic-udp-received; ip netns exec alpha ${pkgs.python3}/bin/python -c 'import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(b\"quic\", (\"11.0.0.2\", 443)); s.sendto(b\"generic\", (\"11.0.0.2\", 4444))'; sleep 1; test ! -e /tmp/seter-quic-udp-received; test ! -e /tmp/seter-generic-udp-received")
      machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 11.0.0.2 853")

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
      machine.succeed("ip netns exec alpha curl --noproxy '*' --fail --silent http://api.wild.example/ | grep -F 'allowed upstream'")
      machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/wild-apex-denied --write-out '%{http_code}' -H 'Host: wild.example' http://11.0.0.2/) = 403")
      machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/wild-deep-denied --write-out '%{http_code}' -H 'Host: deep.api.wild.example' http://11.0.0.2/) = 403")
      machine.succeed("ip netns exec alpha curl --proxy http://10.100.0.1:${toString config.seter.host.proxy.explicitPort} --fail --silent http://allowed.example/ | grep -F 'allowed upstream'")
      machine.succeed("test $(ip netns exec alpha curl --proxy http://10.100.0.1:${toString config.seter.host.proxy.explicitPort} --silent --output /tmp/explicit-denied --write-out '%{http_code}' http://denied.example/) = 403; grep -F 'not in this workspace' /tmp/explicit-denied")
      machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --fail --silent http://allowed.example/ http://allowed.example/index.html | grep -c 'allowed upstream') = 2")
      machine.succeed("ip netns exec alpha curl --noproxy '*' --fail --silent -H 'Host: allowed.example' http://11.0.0.1/ | grep -F 'allowed upstream'")
      machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/denied --write-out '%{http_code}' -H 'Host: denied.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/denied")
      machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/child-denied --write-out '%{http_code}' -H 'Host: child.allowed.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/child-denied")
      machine.succeed("test $(ip netns exec beta curl --noproxy '*' --silent --output /tmp/beta-denied --write-out '%{http_code}' -H 'Host: allowed.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/beta-denied")
      machine.succeed("ip netns exec alpha curl --noproxy '*' --silent -H 'Host: denied.example' 'http://11.0.0.2/private?seter-sensitive-query=1' >/dev/null")
      machine.succeed("ip netns exec beta dig @10.100.0.1 beta-only-observation.example A | grep -F 'status: REFUSED'")
      machine.succeed("seter audit alpha --since 1h > /tmp/alpha-audit; grep -F denied.example /tmp/alpha-audit; grep -F direct-tcp /tmp/alpha-audit; ! grep -F beta-only-observation.example /tmp/alpha-audit; ! grep -F seter-sensitive-query /tmp/alpha-audit")
      machine.succeed("seter audit alpha --since 1h --paths > /tmp/alpha-audit-paths; grep -F seter-sensitive-query /tmp/alpha-audit-paths")
      machine.succeed("ip netns exec alpha curl --noproxy '*' --insecure --fail --silent https://allowed.example/index.html | grep -F 'allowed upstream'")
      machine.succeed("ip netns exec alpha curl --proxy http://10.100.0.1:${toString config.seter.host.proxy.explicitPort} --cacert /var/lib/seter-proxy-public/seter-proxy-ca-cert.pem --fail --silent https://allowed.example/index.html | grep -F 'allowed upstream'")
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
      machine.succeed("rm -f /tmp/seter-secret-received /tmp/secret-body /tmp/secret-headers; ip netns exec alpha curl --proxy http://10.100.0.1:${toString config.seter.host.proxy.explicitPort} --cacert /var/lib/seter-proxy-public/seter-proxy-ca-cert.pem --fail --silent --compressed --dump-header /tmp/secret-headers --output /tmp/secret-body -H 'Authorization: token seter-placeholder-0123456789abcdef' https://allowed.example/secret-gzip")
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
      machine.succeed("printf 'CONNECT allowed.example:22 HTTP/1.1\\r\\nHost: allowed.example:22\\r\\n\\r\\n' | ip netns exec alpha ${lib.getExe pkgs.netcat} -w 2 10.100.0.1 ${toString config.seter.host.proxy.explicitPort} | grep -F '403'")
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
      machine.succeed("ip netns exec alpha curl --proxy http://10.100.0.1:${toString config.seter.host.proxy.explicitPort} --cacert ${proxyTestCertificate}/cert.pem --fail --silent https://passthrough.example/index.html | grep -F 'allowed upstream'")
      machine.succeed("ip netns exec alpha curl --noproxy '*' --cacert ${proxyTestCertificate}/cert.pem --fail --silent --resolve passthrough.example:443:11.0.0.1 https://passthrough.example/index.html | grep -F 'allowed upstream'")
      machine.succeed("test $(ip netns exec alpha curl --noproxy '*' --silent --output /tmp/passthrough-http-denied --write-out '%{http_code}' -H 'Host: passthrough.example' http://11.0.0.2/) = 403; grep -F 'not in this workspace' /tmp/passthrough-http-denied")
      machine.succeed("test $(ip netns exec beta curl --noproxy '*' --insecure --silent --output /tmp/passthrough-beta-denied --write-out '%{http_code}' --resolve passthrough.example:443:11.0.0.2 https://passthrough.example/) = 403; grep -F 'not in this workspace' /tmp/passthrough-beta-denied")
      machine.fail("ip netns exec alpha ${lib.getExe pkgs.netcat} -z -w 1 10.100.0.1 ${toString config.seter.host.proxy.port}")
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
      machine.succeed("rm -rf /run/systemd/system/nftables.service.d; systemctl daemon-reload; systemctl reset-failed nftables.service seter-dns-alpha.service seter-tcp-egress-alpha.service seter-proxy.service seter-tap-alpha.service seter-identity-virtiofsd-alpha.service seter-runtime-alpha.target")

      # A proxy startup failure must also keep the workspace TAP absent.
      machine.succeed("systemctl start nftables.service; mkdir -p /run/systemd/system/seter-proxy.service.d; printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/false\\n' > /run/systemd/system/seter-proxy.service.d/fail.conf; systemctl daemon-reload")
      machine.fail("systemctl start seter-runtime-alpha.target")
      machine.fail("ip link show dev seter-alpha")
      machine.succeed("rm -rf /run/systemd/system/seter-proxy.service.d; systemctl daemon-reload; systemctl reset-failed seter-proxy.service seter-tap-alpha.service seter-identity-virtiofsd-alpha.service seter-runtime-alpha.target")
    '';
}
