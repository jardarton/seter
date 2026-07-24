{
  name,
  ip,
  hostname ? "${name}.vm",
  memory ? "4G",
  cpuQuota ? "200%",
  allowedHTTPHosts ? [ ],
  passthroughHosts ? [ ],
  allowedTCP ? [ ],
  secrets ? { },
}:
{
  inherit
    name
    ip
    hostname
    secrets
    ;

  resources = {
    inherit memory cpuQuota;
  };

  egress = {
    httpHosts = allowedHTTPHosts;
    inherit passthroughHosts;
    tcp = allowedTCP;
  };
}
