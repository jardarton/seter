# TC-0001: Compromised Joyfill npm beta releases

## Source

- **Report:** [Two Joyfill npm Beta Releases Compromised to Deliver DEV#POPPER Remote Access Trojan](https://socket.dev/blog/joyfill-npm-beta-releases-compromised)
- **Publisher:** Socket Research Team
- **Published:** 2026-07-28
- **Accessed:** 2026-07-29

This document summarizes the linked report and evaluates the reported behavior against Seter's currently implemented boundary. It does not independently verify Socket's analysis.

## Summary

Two beta releases in the `@joyfill` npm namespace contained obfuscated JavaScript added to otherwise legitimate package bundles. In the functional path, importing the CommonJS package entrypoint was enough to start the implant. It did not depend on an npm lifecycle script, so disabling install scripts would not prevent execution after import.

The implant used public Tron, Aptos, and BNB Smart Chain transaction data as a mutable payload-discovery mechanism. Socket recovered two payload paths: an in-process chain ending in a Node.js remote-access trojan associated with the DEV#POPPER family, and a detached Node.js downloader that requested and evaluated a separate boot payload. Socket also retrieved related downstream samples, including a Python credential stealer, while noting that those captures could not be proven to have been returned to every affected Joyfill host.

## Affected releases

| Package | Version | Reported behavior |
|---|---|---|
| `@joyfill/layouts` | `0.1.2-2773.beta.0` | Functional import-time implant in the CommonJS entrypoint |
| `@joyfill/components` | `4.0.0-rc24-2773-beta.4` | Same injection present in several bundles; a throwing dynamic-require shim reportedly prevents normal dependency resolution in the published Rollup artifact |

Socket found no matching implant in the preceding versions it examined:

- `@joyfill/layouts@0.1.1`
- `@joyfill/components@4.0.0-rc24`

Socket also reported that other public `@joyfill` packages checked during its analysis did not contain the signature.

## Publication and compromise evidence

Both affected releases used the `2773` prerelease marker and were published by the same npm identity with Node.js 18.20.0 and npm 10.5.0:

- `@joyfill/layouts@0.1.2-2773.beta.0` at `2026-07-28T10:54:57.311Z`
- `@joyfill/components@4.0.0-rc24-2773-beta.4` at `2026-07-28T11:03:59.568Z`

The emitted source maps contained identifiers from the implant, and the layouts source map attributed the appended code to `src/utils/reactGridLayoutUtils.js`. Socket concluded that the malicious code was present when the bundles were built rather than appended only to the final npm tarballs. The available evidence did not distinguish among compromise of a developer workstation, source repository, CI environment, or publishing credentials.

## Execution chain

### Import-time bootstrap

The implant was appended to legitimate package code and concealed with several layers of JavaScript obfuscation. In the layouts CommonJS bundle it exposed Node.js module primitives through global variables, decrypted an embedded resolver, and executed it using dynamic function construction.

The bootstrap set the campaign marker `A9-0135-3` and started two payload paths:

1. An in-process resolver that evaluated its result in the importing process.
2. A detached `node -e` process with ignored standard streams, a hidden window on Windows, and `unref()` so it could outlive the original build, test, or CLI process.

### Blockchain-backed payload resolution

The resolver attempted to obtain a BNB Smart Chain transaction hash from a hard-coded Tron account, with an Aptos account as fallback. It then fetched the BSC transaction, transformed and XOR-decrypted data stored in its input, and evaluated the resulting JavaScript.

The first recovered in-process payload repeated this blockchain-backed resolution technique for a second stage. Socket recovered a final 77,276-byte Node.js payload from that chain.

Because the blockchain records acted as pointers, an operator could change downstream payload selection without publishing another npm package version.

### Detached boot downloader

The parallel branch launched a detached Node.js bootstrap. For the Joyfill campaign marker it selected `23[.]27[.]13[.]43`, requested `/$/boot`, sent `Sec-V: A9-0135-3`, XOR-decrypted the response, and evaluated it.

Socket retrieved two live responses that decrypted with the key embedded in this branch. The captures matched the campaign infrastructure and markers, but their retained request provenance was insufficient to prove that either response was delivered to a particular infected Joyfill host.

## Reported payload capabilities

### Node.js remote-access trojan

The recovered Node.js payload reportedly supported:

- Collection of hostname, operating-system, process, session, and public-IP information.
- A Socket.IO remote-control channel.
- Evaluation of supplied JavaScript and execution of interpreter or shell commands.
- Directory listing, file modification, file upload, and retrieval of additional JavaScript.
- Clipboard collection through PowerShell on Windows, `pbpaste` on macOS, and `xclip` or `xsel` on Linux.
- On-demand installation of `axios` and `socket.io-client` into its working directory.
- Avoidance of selected CI, development, and sandbox hostnames.
- Persistence by modifying files routinely loaded by VS Code, Cursor, Antigravity, Discord Desktop, GitHub Desktop, or the global npm CLI.

Reported persistence targets included:

- `@vscode/deviceid` within VS Code, Cursor, and Antigravity installations
- Discord Desktop's core module
- GitHub Desktop's `resources/app/main.js`
- `node_modules/npm/lib/cli.js` in the global npm installation

### Related Python credential stealer

A captured downstream Python payload reportedly collected:

- Environment and host information.
- Windows Credential Manager and Linux Secret Service data.
- Chromium and Firefox browser data.
- Browser-extension storage associated with wallets and password managers.
- Git credentials and GitHub CLI configuration.
- VS Code storage and GitHub Desktop logs.

It supported platform-specific browser decryption through Windows DPAPI, macOS Keychain, and Linux Secret Service or KWallet. It staged collected data under `%USERPROFILE%\\.npm` or `/tmp/.npm`, created an AES-encrypted ZIP, and uploaded the archive. Socket assessed this sample with medium likelihood as an iteration of OmniStealer, but did not claim that every execution of the compromised Joyfill packages received it.

## Malware-family assessment

Socket associated the initial loader with the PolinRider family based on its global markers, multi-chain resolver structure, and XOR keys. It associated the recovered remote-access tooling with DEV#POPPER based on the `Sec-V` protocol marker, `/$/boot` endpoint, decryption key, Socket.IO command vocabulary, and developer-tool persistence behavior.

The report describes these as code-family assessments, not attribution of the Joyfill compromise to a particular actor or group.

## Indicators of compromise

The following indicators are reproduced from Socket's report for defensive reference. Defanged network indicators retain the report's notation.

### Package files

- Layouts: `dist/index.cjs.js`, `dist/index.es.js`
- Components: `dist/index.js`, `dist/index.esm.js`, `dist/joyfill.min.js`

### Network and protocol

- `api[.]trongrid[.]io`
- `fullnode[.]mainnet[.]aptoslabs[.]com`
- `bsc-dataseed[.]binance[.]org`
- `bsc-rpc[.]publicnode[.]com`
- `166[.]88[.]134[.]62:443`
- `166[.]88[.]134[.]62:80`
- `23[.]27[.]13[.]43/$/boot`
- `198[.]105[.]127[.]210:443`
- `198[.]105[.]127[.]210:80`
- `23[.]27[.]202[.]27:443`
- `23[.]27[.]202[.]27:27017`
- HTTP header marker: `Sec-V: A9-0135-3`

### SHA-256

| Artifact | SHA-256 |
|---|---|
| Layouts archive | `adc4af90540d33cd1e98f44b51482ae9250fbeb97d6f8d7841c81b618cb2c6e6` |
| Layouts CommonJS bundle | `8e8b90dedd456ded0c5748119836e1ca1066112bc569c1b41ca70eb931d1d4dc` |
| Layouts ESM bundle | `5f6a92006ca2ea4b464d66fb41af777edce7296939a7c6ee491e2b3cbfe09848` |
| Components archive | `bcc93dc55bc7daedf4ca57254f0e7f1c40e09851eab98fe10cde801982db17` |
| Components `dist/index.js` | `1352ad22c99983d91e600348b7cbf58235131b1ee34cea9f09623206d5b7dea7` |
| Components `dist/index.esm.js` | `67c6ef602cc850f10d935fee53fa40440df841adf081563bf4fc2631a71249ce` |
| Components `dist/joyfill.min.js` | `c5742ea1875ecd2360022624149994909cd0546e221e4203dffd01f48de45469` |
| First in-process payload | `cb46f12d70824ea24ed1f8bcf45bf3f86680e02a9089aafc03b27f691be57be3` |
| Decoded tier-two resolver | `f452f9cfa539f4a1fe25187a99a484391290d5dbaa422ba455edf6b04f81b7d1` |
| Detached second payload | `78f0de8682e0e894a5784eb7e95db4da6088f528918ca3107dd1e76f80a561d8` |
| Decoded detached bootstrap | `ae7565109fd01b88d82acf7f73ab20709cbc2c9f26fdea13e429ccc87a55d4fb` |
| Final Node.js RAT | `26351aed0397158d3a3b8cc8fd3047d4c015d264c9895f10f20f1521b974ed18` |
| Preserved boot capture | `26e679eaf1e9baeb7c55eb48db482301171d4d26e1728544b23734a90dc70e1b` |
| Preserved boot capture | `2cfede38fb121a71a2f3607474aa8cd588a99f51b37e5e6f0d8cb789fa275032` |
| Preserved Python stealer capture | `36ff00b45e67baa7e3674b0c80f48e88737264c61e5c6b3b091200972de8157c` |

### Blockchain identifiers

#### Tron accounts

- `TMfKQEd7TJJa5xNZJZ2Lep838vrzrs7mAP`
- `TXfxHUet9pJVU1BgVkBAbrES4YUc1nGzcG`
- `TA48dct6rFW8BXsiLAtjFaVFoSuryMjD3v`

#### Aptos accounts

- `0xbe037400670fbf1c32364f762975908dc43eeb38759263e7dfcdabc76380811e`
- `0x3f0e5781d0855fb460661ac63257376db1941b2bb522499e4757ecb3ebd5dce3`
- `0x533b2dbcaeff19cd1f799234a27b578d713d8fcaa341b7501e4526106483e0b1`

#### BNB Smart Chain transactions

- `0x18a8420f727f2405f9d1805ad887b31029b584b2ff5a7ec0f57c72635183e99d`
- `0x7ffb4efddd96e20aec90724be2ac9a71c138a9af697b9fb8224bbf80ea4f22be`
- `0xb6c725890be6890fd2c735eedc47e24b85a350301f6c19a3864e43c35e470968`

## Response guidance reported by Socket

Socket recommended removing the affected versions from lockfiles, caches, mirrors, build images, and deployment artifacts and pinning independently verified versions. Because execution occurred at import time, it warned that `npm install --ignore-scripts` was not a mitigation.

For systems that imported an affected release, Socket recommended treating the host as potentially compromised, isolating it, preserving logs and dependency artifacts, checking the listed persistence targets, and rotating reachable credentials from a separate trusted machine. It also recommended reviewing endpoint and CI telemetry for detached Node.js processes, the listed infrastructure, the `Sec-V` marker, and unexpected blockchain RPC traffic.

## Evaluation against Seter

### Evaluation basis

This evaluation covers Seter `0.1.0` at repository commit `74d92a4`. It is a design-and-implementation review, not an execution of the malware samples.

The conclusion assumes:

- the affected package is imported inside a correctly deployed Seter workspace using the trusted `default` Guest Profile;
- the workspace has a least-privilege Policy File, with its approved repository and any package-registry hosts granted but none of the incident's blockchain or command-and-control destinations granted;
- real credentials are supplied only through Seter's destination-bound secret injection; and
- the malware does not have a guest-to-host VM escape. Deliberate containment of a VM-escape exploit is outside Seter's threat model.

A workspace's actual Policy Grants are decisive. Seter does not ship an IOC blocklist: it blocks these destinations because they have not been granted, not because it recognizes DEV#POPPER, PolinRider, Joyfill, or any listed hash.

### Overall verdict

**Seter would likely have broken the recovered network-dependent payload chains and substantially reduced the incident's blast radius, but it would not have prevented the compromised package from being installed, imported, or executing its initial JavaScript.**

Under the assumptions above, both the Tron lookup and Aptos fallback would be denied. The parallel request to `23.27.13.43/$/boot` would also be denied, as would the reported RAT endpoints and Python-stealer upload destinations. The recovered second stages therefore would not be expected to arrive or establish command and control.

The workspace must nevertheless be treated as compromised from the moment the package is imported. The bootstrap can run commands, inspect guest data, alter the repository and Home Volume, and start detached processes before any network denial occurs. Seter is primarily a containment and authority-reduction boundary for this case, not package malware detection or application-level execution prevention.

### Attack-chain breakdown

| Threat step | Expected Seter result | Handling and residual risk |
|---|---|---|
| Compromise of the developer machine, source repository, CI, or npm publishing identity | **Only a developer-workstation compromise is contained** | Seter isolates code that executes in its workspace. It does not secure an external source host, CI runner, npm account, or publishing credential, and it cannot determine which of those introduced the malicious bundle. |
| Download of an affected Joyfill release | **Not prevented when npm egress is granted** | Seter has no npm advisory, signature, provenance, lockfile, prerelease, or artifact-hash policy. A package registry needed by the project can be granted, in which case the affected tarball is downloaded normally. |
| Import-time CommonJS bootstrap | **Not prevented; contained to the guest** | Disabling lifecycle scripts is irrelevant to this path, and Seter does not restrict dynamic JavaScript evaluation. The code executes with the workspace user's authority inside the VM. |
| Obfuscation, dynamic function construction, and in-process evaluation | **Not prevented** | Seter does not inspect JavaScript or classify process behavior. These techniques do not bypass the VM or host network policy by themselves. |
| Detached `node -e` child | **Process creation succeeds inside the VM** | Seter is not a per-process sandbox. Detachment can outlive the importing build, test, or CLI process while the workspace remains running, but it cannot outlive `seter down` as a running process. A subsequent clean boot has an ephemeral root, although writable persistent volumes can still carry modified state. |
| Tron and Aptos payload discovery | **Blocked unless explicitly granted** | Guest DNS accepts only names derived from the workspace's grants. `api.trongrid.io` and `fullnode.mainnet.aptoslabs.com` receive no usable resolution under the assumed policy, and direct external DNS is blocked. |
| BNB Smart Chain transaction retrieval | **Blocked unless explicitly granted** | The Binance and PublicNode RPC names are subject to the same DNS and intercepted-HTTP allowlists. A mutable blockchain pointer does not bypass destination policy. If an operator grants an RPC host, however, Seter does not inspect or distrust JavaScript encoded in an allowed response. |
| Request to `23.27.13.43/$/boot` | **Blocked unless that exact HTTP destination is granted** | TCP ports 80 and 443 are forced through the HTTP policy boundary. A raw IP, forged packet destination, or ignored proxy environment does not bypass transparent interception. The request path and `Sec-V` header are not independently used as deny indicators. |
| RAT Socket.IO and other listed C2 connections | **Blocked unless destination and protocol are granted** | HTTP/HTTPS traffic needs a matching HTTP or passthrough grant. Non-HTTP ports, including the reported `27017`, need an exact direct-TCP address-and-port grant. Arbitrary UDP, IPv6, ICMP, and other IP protocols remain denied. |
| Operator changes the payload behind a blockchain pointer | **Policy-dependent** | Changing payload bytes or transaction pointers needs no Seter policy change if all subsequent traffic stays on an already granted destination. Seter controls destination authority, not response provenance or content. Moving stages to a legitimately granted package registry or API would likewise weaken this mitigation. |
| Remote shell, JavaScript evaluation, and file commands after C2 | **Available inside the workspace if C2 succeeds** | Once instructions reach the implant, it can execute ordinary user commands and read or modify data available to that guest user. Seter does not impose an in-guest command allowlist. The host VM boundary still limits the reachable filesystem and network authority. |
| Payload upload and data exfiltration | **Blocked to ungranted destinations; possible through granted ones** | The IOC endpoints would be denied under the assumed policy. Seter is not data-loss prevention for an allowed destination: compromised code may send workspace data to any API operation or path that an existing grant makes usable. Passthrough traffic is destination-checked but opaque. |
| CI/development/sandbox hostname avoidance | **Not detected, but does not weaken enforcement** | Seter does not identify malware based on hostname checks. Skipping execution can impede observation, but host nftables, DNS, proxy, and credential policy do not depend on the malware deciding it is in a sandbox. |

The concrete expected denials are therefore:

- DNS or HTTP policy denials for the listed Tron, Aptos, Binance, and PublicNode names;
- HTTP/TLS policy denials for the listed raw-IP endpoints on ports 80 and 443, including `/$/boot`; and
- default-deny direct-TCP handling for listed non-HTTP ports such as `27017`.

An operator grant for any of those exact names or addresses changes the result. Relevant Host Patterns also matter: for example, `*.binance.org` would authorize `bsc-dataseed.binance.org`, and `*.publicnode.com` would authorize `bsc-rpc.publicnode.com`. Seter never creates such grants from observations automatically, but an operator can deliberately add them.

### Payload-capability breakdown

| Reported capability | Seter handling |
|---|---|
| Hostname, OS, process, and session collection | The malware can inventory the guest and its processes. It sees a Seter guest identity and workspace state, not the host's process table or another workspace. Obtaining public-IP data still requires an allowed network service. |
| Arbitrary shell/interpreter commands | Allowed with the guest user's authority. The security boundary is the VM, not a shell-command filter. |
| Directory listing, file modification, and upload | The Project and Home Volumes are fully exposed to the workspace user. The malware cannot ambiently enumerate the host home, another workspace, or unrelated host Nix-store paths. Upload still needs an allowed egress destination. |
| Clipboard collection through `xclip` or `xsel` | The default Guest Profile includes neither tool and exposes no host clipboard, X11 forwarding, or desktop session. A clipboard deliberately added inside the guest would be guest-local authority and could be read. This does not address other classes of malicious terminal-output behavior. |
| Installing `axios` and `socket.io-client` | Not prevented if the required package-registry destination is granted. The packages can be written into the project, Home Volume caches, or other workspace-private state. |
| Persistence in VS Code, Cursor, Discord, GitHub Desktop, or global npm | Most named targets are absent from the minimal default profile. Nix-provided global applications reside in immutable store paths rather than a normal user-writable installation. However, Seter does not generally prevent persistence in writable project files, shell configuration, editor-server state, language caches, or user-installed tooling in the Home Volume. |
| Environment and credential-store theft | The process can read its own guest environment, but Seter exports public secret placeholders rather than real injected values. The default profile does not expose the host Credential Manager, Keychain, Secret Service, KWallet, browser profiles, GitHub CLI state, or Git credential files. Equivalent tools or secrets deliberately created inside the workspace remain stealable. |
| Browser and extension theft | No host browser profile or host home is mounted. Browser or extension data created inside that same workspace would be in scope for the compromise. |
| Staging an encrypted archive in `/tmp/.npm` | The malware can stage guest-readable data in guest `/tmp`; encryption does not affect containment. The tmpfs root is discarded on reboot, but the archive may be uploaded first if an allowed destination is available. |

### Credentials and repository authority

Destination-bound injection materially improves this case, with an important limit:

- The real credential value is not present in the guest environment, files, command arguments, or Nix store. A stealer normally obtains only the public placeholder.
- The proxy substitutes that placeholder only in configured headers over intercepted HTTPS to the exact bound host. A leaked placeholder cannot authenticate elsewhere.
- A repository credential is further limited to the approved repository's exact Git smart-HTTP paths, preventing use against sibling repositories.
- Compromised code can still **exercise** granted authority without learning its value. It can fetch or push the approved repository if that credential permits it. A malicious commit pushed this way can extend the supply-chain compromise.
- Non-repository API credentials are host-and-header bound, not generally method-, path-, or operation-bound. An npm publishing token bound to the npm service, for example, could still be used by malicious code to publish if the token and allowed API support that action.
- Data legitimately returned by an authorized service is guest-visible. Exact secret reflection is redacted, but encoded, transformed, derived, or unrelated sensitive data is not a DLP boundary.

Seter therefore prevents bulk credential-file theft from the host and narrows credential scope, but it does not make a write-capable credential safe to expose as usable authority to hostile workspace code. Reachable repository and publishing authority should still be reviewed and rotated from a trusted machine after compromise.

### Filesystem, host, and resource containment

For this incident, Seter's main containment gains are:

- no host-home mount, SSH-agent forwarding, X11 forwarding, host browser profile, or ambient host credential files;
- one workspace-specific Project Volume and Home Volume, with no access to another workspace's state;
- a closure-filtered read-only Store View instead of the full host `/nix/store`;
- host-owned isolation from the host, private LAN, other workspace TAPs, and ungranted routed destinations; and
- configured VM memory and CPU limits plus fixed-capacity Project, Home, and private Nix-store images.

These controls turn the developer host and unrelated projects into out-of-scope targets for this user-space RAT, absent a VM escape or a separately exposed privileged host service. They do not protect the current workspace from itself. Source files, dirty work, local configuration, caches, and any manually introduced secrets in that workspace can be stolen, corrupted, or deleted.

### Detection and response

Seter provides useful policy evidence but not endpoint detection:

- DNS, intercepted HTTP/TLS, passthrough, and direct-TCP allow/deny observations are logged by default and can be reviewed with `seter audit <workspace>`.
- The blockchain names, raw C2 addresses, and unusual direct-TCP ports should appear as denied observations under the assumed policy. Intercepted HTTP auditing can expose `/$/boot`; passthrough records only destination metadata.
- Observations never create grants automatically. An unexplained blockchain RPC or raw-IP request should be investigated rather than approved.
- Seter does not scan package hashes, identify the `Sec-V` marker as malicious, alert on detached Node.js processes, inspect guest persistence targets, or automatically quarantine a workspace.

For response, `seter down` terminates running guest processes and restores containment while evidence is assessed. `seter reset <workspace> --all-state` can replace the Home and private Nix-store volumes, clearing many caches and user-level persistence locations, but deliberately preserves the Project Volume. That volume must be inspected and restored from trusted source or separately destroyed; reset alone does not make an imported workspace trustworthy. Preserve audit logs and suspect volumes before destructive action when forensic evidence matters.
