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
  projectImage ? null,
  nixStoreImage ? null,
  nixStoreSizeMiB ? null,
  allowedHTTPHosts ? [ ],
  passthroughHosts ? [ ],
  allowedTCP ? [ ],
  hostServices ? [ ],
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

  storage =
    (if projectImage == null then { } else { image = projectImage; })
    // (if nixStoreImage == null then { } else { inherit nixStoreImage; })
    // (if nixStoreSizeMiB == null then { } else { inherit nixStoreSizeMiB; });

  egress = {
    httpHosts = allowedHTTPHosts;
    inherit passthroughHosts;
    tcp = allowedTCP;
  };

  inherit hostServices secrets;
}
// (if hostname == null then { } else { inherit hostname; })
