# TODO

## Automate GitHub repository credentials

Manual per-workspace PAT creation and rotation is too tedious for repeatable
workspace onboarding. Investigate a host-side GitHub App credential broker.

The intended flow is:

- use GitHub's App Manifest flow for a one-time guided setup;
- require explicit account-owner confirmation when creating and installing the
  App;
- store the App private key in the consumer's secret manager, never in Seter's
  public configuration or a guest;
- mint short-lived installation access tokens narrowed to one repository and
  the minimum required permissions;
- expose each token to Seter as a runtime credential and inject it only for the
  registered repository's exact Git smart-HTTP paths;
- refresh tokens before their roughly one-hour expiry without exposing them to
  the workspace;
- handle credential reload without unnecessarily disrupting unrelated active
  workspace traffic;
- support selected-repository installations for tighter authority, while
  documenting the authority trade-off of all-repository installations.

A consumer-owned implementation may be useful for proving the design before
adding a general dynamic credential-provider interface to Seter.
