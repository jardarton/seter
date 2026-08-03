use std::{
    collections::{BTreeMap, HashSet},
    env,
    fs::File,
    io::Read,
    net::Ipv4Addr,
    path::{Path, PathBuf},
};

use anyhow::{bail, ensure, Context, Result};
use serde::Deserialize;

pub const REGISTRY_PATH: &str = "/etc/seter/workspaces.json";
const REGISTRY_VERSION: u32 = 6;
pub const RUNNER_IDENTITY_VERSION: u32 = 3;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registry {
    version: u32,
    pub workspaces: BTreeMap<String, Workspace>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Workspace {
    pub hostname: String,
    pub guest_profile: String,
    pub repository: Repository,
    pub runner: Runner,
    pub network: Network,
    pub resources: Resources,
    pub ssh: Ssh,
    pub storage: Storage,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Repository {
    pub url: String,
    pub branch: Option<String>,
    pub checkout_name: String,
    pub credential: Option<RepositoryCredential>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RepositoryCredential {
    pub name: String,
    pub placeholder: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Runner {
    pub path: PathBuf,
    pub identity: RunnerIdentity,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunnerIdentity {
    pub version: u32,
    pub workspace: String,
    pub hostname: String,
    pub network: RunnerNetworkIdentity,
    pub proxy: RunnerProxyIdentity,
    pub ssh: RunnerSshIdentity,
    pub guest_profile: String,
    pub resources: RunnerResourcesIdentity,
    pub storage: Storage,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunnerNetworkIdentity {
    pub address: Ipv4Addr,
    pub mac: String,
    pub tap: String,
    pub gateway: Ipv4Addr,
    pub prefix_length: u8,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RunnerProxyIdentity {
    pub url: String,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RunnerSshIdentity {
    pub user: String,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunnerResourcesIdentity {
    pub memory_mi_b: u64,
    pub vcpu: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Network {
    pub address: Ipv4Addr,
    pub mac: String,
    pub tap: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Resources {
    pub memory_mi_b: u64,
    pub vcpu: u32,
    pub cpu_quota_percent: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Ssh {
    pub user: String,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Storage {
    pub project: Volume,
    pub home: Volume,
    pub nix_store: Volume,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Volume {
    pub image: String,
    pub size_mi_b: u64,
}

impl Registry {
    pub fn load_default() -> Result<Self> {
        let path = env::var_os("SETER_REGISTRY").unwrap_or_else(|| REGISTRY_PATH.into());
        Self::load(path)
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let file = File::open(path)
            .with_context(|| format!("failed to open workspace registry {}", path.display()))?;
        Self::from_reader(file)
            .with_context(|| format!("failed to read workspace registry {}", path.display()))
    }

    fn from_reader(reader: impl Read) -> Result<Self> {
        let registry: Self = serde_json::from_reader(reader).context("invalid registry JSON")?;
        registry.validate()?;
        Ok(registry)
    }

    pub fn workspace(&self, name: &str) -> Result<&Workspace> {
        self.workspaces
            .get(name)
            .with_context(|| format!("workspace {name:?} is not configured"))
    }

    fn validate(&self) -> Result<()> {
        if self.version != REGISTRY_VERSION {
            bail!(
                "unsupported workspace registry version {}; expected {}",
                self.version,
                REGISTRY_VERSION
            );
        }

        let mut addresses = HashSet::new();
        let mut macs = HashSet::new();
        let mut taps = HashSet::new();
        let mut hostnames = HashSet::new();

        for (name, workspace) in &self.workspaces {
            ensure!(
                workspace.guest_profile == "default",
                "workspace {name:?} uses unsupported Guest Profile {:?}",
                workspace.guest_profile
            );
            if let Err(error) = validate_repository_url(&workspace.repository.url) {
                bail!("workspace {name:?} has an invalid repository URL: {error}");
            }
            // Mirrors the host module's constraint. Requiring a leading
            // alphanumeric rejects "." and ".." along with any separator, so a
            // checkout name can never escape the project directory.
            let checkout = &workspace.repository.checkout_name;
            ensure!(
                checkout
                    .chars()
                    .next()
                    .is_some_and(|first| first.is_ascii_alphanumeric())
                    && checkout
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-')),
                "workspace {name:?} has an invalid repository checkout name {checkout:?}"
            );
            if let Some(branch) = &workspace.repository.branch {
                ensure!(
                    !branch.trim().is_empty(),
                    "workspace {name:?} has an empty repository branch"
                );
            }
            if let Some(credential) = &workspace.repository.credential {
                ensure!(
                    !credential.name.trim().is_empty(),
                    "workspace {name:?} has an empty repository credential binding"
                );
                ensure!(
                    credential.placeholder.starts_with("seter-placeholder-")
                        && credential.placeholder["seter-placeholder-".len()..].len() >= 16
                        && credential.placeholder["seter-placeholder-".len()..]
                            .chars()
                            .all(|character| character.is_ascii_alphanumeric()
                                || matches!(character, '_' | '-')),
                    "workspace {name:?} has an invalid repository credential placeholder"
                );
            }
            ensure!(
                workspace.runner.path.is_absolute(),
                "workspace {name:?} has a non-absolute deployed Runner path"
            );
            let identity = &workspace.runner.identity;
            ensure!(
                identity.version == RUNNER_IDENTITY_VERSION,
                "workspace {name:?} requires unsupported runner identity version {}",
                identity.version
            );
            ensure!(
                identity.workspace == *name,
                "workspace {name:?} has a runner identity for {:?}",
                identity.workspace
            );
            ensure!(
                identity.hostname.eq_ignore_ascii_case(&workspace.hostname),
                "workspace {name:?} runner identity hostname does not match the registry"
            );
            ensure!(
                identity.network.address == workspace.network.address
                    && identity
                        .network
                        .mac
                        .eq_ignore_ascii_case(&workspace.network.mac)
                    && identity.network.tap == workspace.network.tap,
                "workspace {name:?} runner network identity does not match the registry"
            );
            ensure!(
                identity.network.prefix_length <= 32,
                "workspace {name:?} runner identity has an invalid prefix length"
            );
            ensure!(
                identity.ssh.user == workspace.ssh.user,
                "workspace {name:?} runner SSH identity does not match the registry"
            );
            ensure!(
                identity.guest_profile == workspace.guest_profile,
                "workspace {name:?} Runner Guest Profile does not match the registry"
            );
            ensure!(
                identity.resources.memory_mi_b == workspace.resources.memory_mi_b,
                "workspace {name:?} Runner memory does not match the registry"
            );
            ensure!(
                identity.resources.vcpu == workspace.resources.vcpu,
                "workspace {name:?} Runner vCPU count does not match the registry"
            );
            ensure!(
                identity.storage == workspace.storage,
                "workspace {name:?} runner storage identity does not match the registry"
            );
            ensure!(
                identity.proxy.url.starts_with("http://")
                    && !identity.proxy.url["http://".len()..].is_empty(),
                "workspace {name:?} runner identity has an invalid proxy URL"
            );
            ensure!(
                workspace.resources.memory_mi_b > 0,
                "workspace {name:?} has a zero memory limit"
            );
            ensure!(
                workspace.resources.vcpu > 0,
                "workspace {name:?} has a zero vCPU count"
            );
            ensure!(
                workspace.resources.cpu_quota_percent > 0,
                "workspace {name:?} has a zero CPU quota"
            );
            ensure!(
                !workspace.ssh.user.trim().is_empty(),
                "workspace {name:?} has an empty SSH user"
            );
            let volumes = [
                ("Project", &workspace.storage.project),
                ("Home", &workspace.storage.home),
                ("Nix store", &workspace.storage.nix_store),
            ];
            let mut image_names = HashSet::new();
            for (label, volume) in volumes {
                ensure!(
                    !volume.image.trim().is_empty()
                        && !volume.image.contains('/')
                        && volume.image != "."
                        && volume.image != "..",
                    "workspace {name:?} has an invalid {label} image name"
                );
                ensure!(
                    volume.size_mi_b > 0,
                    "workspace {name:?} has a zero-sized {label} volume"
                );
                ensure!(
                    image_names.insert(&volume.image),
                    "workspace {name:?} reuses volume image name {:?}",
                    volume.image
                );
            }
            ensure!(
                addresses.insert(workspace.network.address),
                "workspace {name:?} reuses IPv4 address {}",
                workspace.network.address
            );
            ensure!(
                macs.insert(workspace.network.mac.to_ascii_lowercase()),
                "workspace {name:?} reuses MAC address {}",
                workspace.network.mac
            );
            ensure!(
                taps.insert(&workspace.network.tap),
                "workspace {name:?} reuses tap interface {}",
                workspace.network.tap
            );
            ensure!(
                hostnames.insert(workspace.hostname.to_ascii_lowercase()),
                "workspace {name:?} reuses hostname {}",
                workspace.hostname
            );
        }

        Ok(())
    }
}

fn validate_repository_url(url: &str) -> Result<()> {
    let remainder = url
        .strip_prefix("https://")
        .context("repository must use HTTPS")?;
    let (authority, path) = remainder
        .split_once('/')
        .context("repository URL must contain an exact repository path")?;
    let host = authority.strip_suffix(":443").unwrap_or(authority);
    ensure!(
        !authority.contains('@')
            && host
                .chars()
                .next()
                .is_some_and(|character| character.is_ascii_alphanumeric())
            && host
                .chars()
                .last()
                .is_some_and(|character| character.is_ascii_alphanumeric())
            && host.chars().all(
                |character| character.is_ascii_alphanumeric() || matches!(character, '.' | '-')
            ),
        "repository URL has an invalid host or port"
    );
    ensure!(
        !path.is_empty() && !path.contains(['?', '#']) && !path.chars().any(char::is_whitespace),
        "repository URL must contain an exact path without a query or fragment"
    );
    let lower_path = path.to_ascii_lowercase();
    ensure!(
        path.split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..")
            && !lower_path.contains("%2e")
            && !lower_path.contains("%2f")
            && !lower_path.contains("%5c"),
        "repository URL path must not contain empty, dot, or encoded separator segments"
    );
    ensure!(
        !authority.contains(':') || authority.ends_with(":443"),
        "repository HTTPS URL may only use port 443"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::Registry;

    const VALID: &str = r#"
    {
      "version": 6,
      "workspaces": {
        "minimal": {
          "hostname": "minimal.vm",
          "guestProfile": "default",
          "repository": {
            "url": "https://git.example/owner/project.git",
            "branch": null,
            "checkoutName": "project",
            "credential": null
          },
          "runner": {
            "path": "/nix/store/test-runner",
            "identity": {
              "version": 3,
              "workspace": "minimal",
              "hostname": "minimal.vm",
              "network": {
                "address": "10.100.0.10",
                "mac": "02:00:00:00:00:aa",
                "tap": "seter-minimal",
                "gateway": "10.100.0.1",
                "prefixLength": 24
              },
              "proxy": { "url": "http://10.100.0.1:18081" },
              "ssh": { "user": "seter" },
              "guestProfile": "default",
              "resources": { "memoryMiB": 4096, "vcpu": 2 },
              "storage": {
                "project": { "image": "minimal-project.img", "sizeMiB": 4096 },
                "home": { "image": "minimal-home.img", "sizeMiB": 4096 },
                "nixStore": { "image": "minimal-nix-store.img", "sizeMiB": 16384 }
              }
            }
          },
          "network": {
            "address": "10.100.0.10",
            "mac": "02:00:00:00:00:aa",
            "tap": "seter-minimal"
          },
          "resources": { "memoryMiB": 4096, "vcpu": 2, "cpuQuotaPercent": 200 },
          "ssh": { "user": "seter" },
          "storage": {
            "project": { "image": "minimal-project.img", "sizeMiB": 4096 },
            "home": { "image": "minimal-home.img", "sizeMiB": 4096 },
            "nixStore": { "image": "minimal-nix-store.img", "sizeMiB": 16384 }
          }
        }
      }
    }
    "#;

    #[test]
    fn parses_version_six_registry() {
        let registry = Registry::from_reader(VALID.as_bytes()).unwrap();
        let workspace = registry.workspace("minimal").unwrap();

        assert_eq!(workspace.network.address.to_string(), "10.100.0.10");
        assert_eq!(
            workspace.runner.path.to_string_lossy(),
            "/nix/store/test-runner"
        );
        assert_eq!(workspace.repository.checkout_name, "project");
        assert_eq!(workspace.runner.identity.guest_profile, "default");
        assert_eq!(workspace.storage.home.size_mi_b, 4096);
    }

    #[test]
    fn rejects_unsupported_version() {
        let input = VALID.replacen("\"version\": 6", "\"version\": 999", 1);
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error
            .to_string()
            .contains("unsupported workspace registry version"));
    }

    #[test]
    fn rejects_non_https_repository() {
        let input = VALID.replacen("https://git.example", "ssh://git.example", 1);
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error.to_string().contains("repository must use HTTPS"));
    }

    #[test]
    fn rejects_ambiguous_repository_paths() {
        for candidate in [
            "https://./owner/project.git",
            "https://git.example/owner/../other.git",
            "https://git.example/owner//project.git",
            "https://git.example/owner/project.git%2f..%2fother.git",
        ] {
            let input = VALID.replacen("https://git.example/owner/project.git", candidate, 1);
            let error = Registry::from_reader(input.as_bytes()).unwrap_err();
            assert!(
                error.to_string().contains("repository URL path must not")
                    || error.to_string().contains("invalid host or port"),
                "repository URL {candidate:?} was not rejected: {error}"
            );
        }
    }

    #[test]
    fn rejects_traversing_checkout_name() {
        for candidate in ["..", ".", "", "../escape", "a/b"] {
            let input = VALID.replacen(
                "\"checkoutName\": \"project\"",
                &format!("\"checkoutName\": {candidate:?}"),
                1,
            );
            let error = Registry::from_reader(input.as_bytes()).unwrap_err();
            assert!(
                error
                    .to_string()
                    .contains("invalid repository checkout name"),
                "checkout name {candidate:?} was not rejected: {error}"
            );
        }
    }

    #[test]
    fn rejects_runner_identity_drift() {
        let input = VALID.replacen(
            "\"memoryMiB\": 4096, \"vcpu\": 2 },\n              \"storage\"",
            "\"memoryMiB\": 2048, \"vcpu\": 2 },\n              \"storage\"",
            1,
        );
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error.to_string().contains("Runner memory does not match"));
    }

    #[test]
    fn rejects_runner_vcpu_identity_drift() {
        let input = VALID.replacen(
            "\"memoryMiB\": 4096, \"vcpu\": 2",
            "\"memoryMiB\": 4096, \"vcpu\": 4",
            1,
        );
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error
            .to_string()
            .contains("Runner vCPU count does not match"));
    }

    #[test]
    fn rejects_reused_storage_image() {
        let input = VALID.replacen("minimal-home.img", "minimal-project.img", 2);
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error.to_string().contains("reuses volume image name"));
    }

    #[test]
    fn reports_unknown_workspace() {
        let registry = Registry::from_reader(VALID.as_bytes()).unwrap();
        let error = registry.workspace("missing").unwrap_err();
        assert!(error.to_string().contains("is not configured"));
    }
}
