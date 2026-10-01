{
  self,
  lib,
  pkgs,
  system,
  validWorkspaces,
}:
let
  lifecycleHelper = lib.getExe self.packages.${system}.seter;
in
pkgs.testers.runNixOSTest {
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
    machine.wait_for_unit("seter-identity-virtiofsd-alpha.service")
    machine.succeed("ip link show dev seter-alpha | grep -F 'master seter0'")
    machine.succeed("bridge -details link show dev seter-alpha | grep -F 'isolated on'")
    machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); uid=$(id -u $account); ip tuntap show dev seter-alpha | grep -F \"user $uid\"")
    machine.succeed("test $(stat -c %a /var/lib/seter/workspaces/alpha) = 700")
    machine.succeed("account=$(stat -c %G /run/lock/seter/alpha.lock); test \"$account\" = $(stat -c %U /var/lib/seter/workspaces/alpha)")
    machine.succeed("test $(stat -c %U /run/lock/seter/alpha.lock) = root")
    machine.succeed("test $(stat -c %a /run/lock/seter/alpha.lock) = 640")
    machine.fail("account=$(stat -c %G /run/lock/seter/alpha.lock); runuser -u $account -- rm -f /run/lock/seter/alpha.lock")
    machine.succeed("ip tuntap show dev seter-alpha | grep -F 'multi_queue'")
    machine.succeed("test -S /run/seter/alpha/virtiofs-identity.sock")
    machine.succeed("test $(stat -c %U:%G /var/lib/seter/identities/alpha/ssh_host_ed25519_key) = root:root")
    machine.succeed("test $(stat -c %a /var/lib/seter/identities/alpha/ssh_host_ed25519_key) = 600")
    machine.succeed("test $(stat -c %U /run/credentials/seter-identity-virtiofsd-alpha.service/ssh_host_ed25519_key) = root")
    machine.fail("runuser -u outsider -- test -r /run/credentials/seter-identity-virtiofsd-alpha.service/ssh_host_ed25519_key")
    machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); runuser -u $account -- test -r /run/credentials/seter-identity-virtiofsd-alpha.service/ssh_host_ed25519_key")
    machine.succeed("account=$(stat -c %U /var/lib/seter/workspaces/alpha); uid=$(id -u $account); main=$(systemctl show --value --property MainPID seter-identity-virtiofsd-alpha.service); test $(awk '/^Uid:/ { print $2 }' /proc/$main/status) = $uid")
    machine.succeed("stat -c %G /run/seter/alpha/virtiofs-identity.sock | grep -E '^seter-alpha-[0-9a-f]{8}$'")
    machine.succeed("main=$(systemctl show --value --property MainPID seter-identity-virtiofsd-alpha.service); for pid in $(cat /proc/$main/task/$main/children); do tr '\\0' ' ' < /proc/$pid/cmdline; done | grep -F -- '--shared-dir=/run/credentials/seter-identity-virtiofsd-alpha.service'")
    machine.succeed("main=$(systemctl show --value --property MainPID seter-identity-virtiofsd-alpha.service); for pid in $(cat /proc/$main/task/$main/children); do tr '\\0' ' ' < /proc/$pid/cmdline; done | grep -F -- '--readonly'")

    # An unexpected daemon failure must restart instead of being
    # classified as a successful exit and silently disabling the
    # identity service.
    machine.succeed("main=$(systemctl show --value --property MainPID seter-identity-virtiofsd-alpha.service); echo $main > /tmp/identity-main; child=$(cat /proc/$main/task/$main/children); kill -KILL $child")
    machine.wait_until_succeeds("old=$(cat /tmp/identity-main); new=$(systemctl show --value --property MainPID seter-identity-virtiofsd-alpha.service); test $new -ne 0 -a $new -ne $old; systemctl is-active --quiet seter-identity-virtiofsd-alpha.service; test -S /run/seter/alpha/virtiofs-identity.sock")

    machine.succeed("systemctl stop seter-runtime-alpha.target")
    machine.wait_until_fails("ip link show dev seter-alpha")
    machine.wait_until_fails("test -e /run/seter/alpha/virtiofs-identity.sock")
    machine.wait_until_fails("systemctl is-active --quiet seter-dns-alpha.service")
    machine.succeed("test $(systemctl show --value --property Result seter-identity-virtiofsd-alpha.service) = success")
    machine.succeed("systemctl is-active --quiet seter-bridge.service")
    machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

    machine.succeed("set +e; seter status alpha > /tmp/seter-status; code=$?; set -e; test $code = 3; grep -F 'state: stopped' /tmp/seter-status")
    machine.fail("su - outsider -c 'seter up alpha'")
    machine.succeed("set +e; su - operator -c 'seter up missing' 2> /tmp/missing-workspace; code=$?; set -e; test $code = 1; grep -F 'is not configured' /tmp/missing-workspace")
    machine.fail("su - operator -c 'sudo -n true'")
    machine.fail("su - operator -c 'sudo -n -u outsider ${lifecycleHelper} __start alpha'")
    machine.fail("su - operator -c 'seter __start alpha'")
    # Audit uses the same packaged helper and NixOS sudo wrapper,
    # while remaining strictly root-only on the privileged side.
    machine.succeed("su - operator -c 'PATH=/no-sudo ${lifecycleHelper} audit alpha'")
    machine.fail("su - outsider -c 'seter audit alpha'")
    machine.succeed("set +e; su - operator -c 'SETER_TEST_MODE=1 SETER_STATE_DIR=/tmp/test-state seter __audit alpha' 2> /tmp/audit-not-root; code=$?; set -e; test $code = 1; grep -F 'must run as root' /tmp/audit-not-root")
    # Even a direct root invocation discards test configuration before
    # registry loading or systemd calls; sudo's env reset is not needed.
    machine.succeed("SETER_REGISTRY=/dev/null SETER_TEST_MODE=1 SETER_STATE_DIR=/tmp/test-state seter __audit alpha")
    machine.succeed("SETER_REGISTRY=/dev/null SETER_TEST_MODE=1 SETER_STATE_DIR=/tmp/test-state SETER_SYSTEMCTL=/bin/false seter __stop alpha")
    machine.succeed("set +e; SETER_REGISTRY=/dev/null seter __audit missing 2> /tmp/audit-missing; code=$?; set -e; test $code = 1; grep -F 'is not configured' /tmp/audit-missing")
    # 4096 MiB of guest RAM plus the default 512 MiB of VMM overhead.
    machine.succeed("test $(systemctl show --value --property MemoryMax seter-vm-alpha.service) = 4831838208")
    machine.succeed("test $(systemctl show --value --property CPUQuotaPerSecUSec seter-vm-alpha.service) = 2s")
    machine.succeed("systemctl cat seter-vm-alpha.service | grep -F '/nix/store/' | grep -F 'microvm-run'")
    machine.fail("systemctl cat seter-vm-alpha.service | grep -F '/var/lib/seter/workspaces/alpha/current'")
    machine.succeed("test -z \"$(systemctl --failed --no-legend)\"")

    machine.succeed("systemctl stop seter-bridge.service")
    machine.succeed("ip link add name seter0 type bridge")
    machine.fail("systemctl start seter-bridge.service")
    machine.succeed("ip link show dev seter0")
    machine.succeed("ip link delete dev seter0")
    machine.succeed("systemctl reset-failed seter-bridge.service")
  '';
}
