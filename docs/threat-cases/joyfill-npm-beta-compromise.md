# TC-0001: Compromised Joyfill npm beta releases

## Source

- **Report:** [Two Joyfill npm Beta Releases Compromised to Deliver DEV#POPPER Remote Access Trojan](https://socket.dev/blog/joyfill-npm-beta-releases-compromised)
- **Publisher:** Socket Research Team
- **Published:** 2026-07-28
- **Accessed:** 2026-07-29

This document summarizes the linked report. It does not independently verify Socket's analysis or evaluate the incident against Seter.

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
