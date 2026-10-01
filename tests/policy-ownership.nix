{
  self,
  pkgs,
  system,
  mkHostWith,
  validWorkspaces,
}:
let
  lib = pkgs.lib;
  policyFile = ./fixtures/policy-ownership.toml;
  deployed =
    (mkHostWith {
      inherit policyFile;
      workspaces = validWorkspaces;
    }).config;
  empty = (mkHostWith { workspaces = validWorkspaces; }).config;
  emptyEgress = {
    httpHosts = [ ];
    passthroughHosts = [ ];
    tcp = [ ];
  };
  inlineRejected =
    policyFile: field: value:
    !(builtins.tryEval (
      builtins.deepSeq
        (mkHostWith {
          inherit policyFile;
          workspaces = lib.recursiveUpdate validWorkspaces {
            alpha.egress.${field} = value;
          };
        }).config.seter.host.workspaces.alpha.egress
        true
    )).success;
  changedPolicyFile = pkgs.writeText "seter-changed-policy.toml" ''
    version = 1
    [workspaces.alpha.egress]
    http-hosts = ["new.example.com"]
    passthrough-hosts = ["new.example.net"]
    [[workspaces.alpha.egress.tcp]]
    host = "new.example.org"
    port = 2223
  '';
in
assert lib.all (entry: entry.assertion) deployed.assertions;
assert lib.all (entry: entry.assertion) empty.assertions;
assert empty.seter.host.workspaces.alpha.egress == emptyEgress;
assert deployed.seter.host.workspaces.beta.egress == emptyEgress;
assert lib.all
  (
    file:
    lib.all (field: inlineRejected file field emptyEgress.${field}) [
      "httpHosts"
      "passthroughHosts"
      "tcp"
    ]
  )
  [
    null
    policyFile
  ];
assert inlineRejected policyFile "httpHosts" [ "inline.example.com" ];
assert inlineRejected policyFile "passthroughHosts" [ "inline.example.net" ];
assert inlineRejected policyFile "tcp" [
  {
    host = "inline.example.org";
    port = 2223;
  }
];
pkgs.runCommand "seter-policy-ownership-check"
  {
    nativeBuildInputs = [
      pkgs.jq
      self.packages.${system}.seter
    ];
  }
  ''
    export SETER_REGISTRY=${deployed.environment.etc."seter/workspaces.json".source}
    export SETER_ACTIVE_POLICY=${deployed.environment.etc."seter/policy.json".source}

    # The active projection contains only TOML-owned reviewable grants.
    jq -e '.version == 1 and .workspaces.alpha.egress == {
      "http-hosts": ["api.example.com"],
      "passthrough-hosts": ["downloads.example.net"],
      "tcp": [{host: "ssh.example.org", port: 2222}]
    } and .workspaces.beta.egress == {
      "http-hosts": [], "passthrough-hosts": [], "tcp": []
    }' "$SETER_ACTIVE_POLICY"

    # Automatic repository access survives with no Policy File and is excluded
    # from desired/active comparisons, including when TOML grants are revoked.
    jq -e '.workspaces["10.100.0.10"].httpHosts == ["example.invalid"]' \
      ${builtins.head empty.systemd.services.seter-proxy.restartTriggers}
    jq -e '.allowedNames == ["example.invalid"]' \
      ${builtins.head empty.systemd.services.seter-dns-alpha.restartTriggers}

    seter policy status alpha --file ${policyFile} > agreed
    grep -F 'agree' agreed
    test "$(wc -l < agreed)" = 1

    set +e
    seter policy status alpha --file ${changedPolicyFile} > pending
    code=$?
    set -e
    test "$code" = 2
    for grant in \
      '+ http new.example.com' '- http api.example.com' \
      '+ passthrough new.example.net' '- passthrough downloads.example.net' \
      '+ tcp new.example.org:2223' '- tcp ssh.example.org:2222'; do
      grep -Fx -- "$grant" pending
    done
    test "$(wc -l < pending)" = 7

    # After removing every TOML grant and deploying, status agrees even though
    # the repository's HTTP/DNS authorization remains active.
    printf 'version = 1\n' > revoked.toml
    export SETER_ACTIVE_POLICY=${empty.environment.etc."seter/policy.json".source}
    seter policy status alpha --file revoked.toml > revoked
    grep -F 'agree' revoked
    touch "$out"
  ''
