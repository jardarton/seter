{
  runnerInstallable,
  ip,
  mac,
  tap,
  hostname ? null,
  memoryMiB ? 4096,
  cpuQuotaPercent ? 200,
  sshUser ? "seter",
  knownHostKey ? null,
  allowedHTTPHosts ? [ ],
  passthroughHosts ? [ ],
  allowedTCP ? [ ],
  secrets ? { },
}:
{
  runner.installable = runnerInstallable;

  network = {
    address = ip;
    inherit mac tap;
  };

  resources = {
    inherit memoryMiB cpuQuotaPercent;
  };

  ssh = {
    user = sshUser;
    inherit knownHostKey;
  };

  egress = {
    httpHosts = allowedHTTPHosts;
    inherit passthroughHosts;
    tcp = allowedTCP;
  };

  inherit secrets;
}
// (if hostname == null then { } else { inherit hostname; })
