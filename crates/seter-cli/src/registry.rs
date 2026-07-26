use std::{
    collections::{BTreeMap, HashSet},
    env,
    fs::File,
    io::Read,
    net::Ipv4Addr,
    path::Path,
};

use anyhow::{bail, ensure, Context, Result};
use serde::Deserialize;

pub const REGISTRY_PATH: &str = "/etc/seter/workspaces.json";
const REGISTRY_VERSION: u32 = 3;
pub const RUNNER_IDENTITY_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registry {
    version: u32,
    pub workspaces: BTreeMap<String, Workspace>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub hostname: String,
    pub runner: Runner,
    pub network: Network,
    pub resources: Resources,
    pub ssh: Ssh,
    pub storage: Storage,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Runner {
    pub installable: String,
    #[serde(default)]
    pub identity: Option<RunnerIdentity>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct RunnerIdentity {
    pub version: u32,
    pub workspace: String,
    pub hostname: String,
    pub network: RunnerNetworkIdentity,
    pub proxy: RunnerProxyIdentity,
    pub ssh: RunnerSshIdentity,
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
    pub cpu_quota_percent: u32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Ssh {
    pub user: String,
    pub known_host_key: Option<String>,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Storage {
    pub image: String,
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
                !workspace.runner.installable.trim().is_empty(),
                "workspace {name:?} has an empty runner installable"
            );
            if let Some(identity) = &workspace.runner.identity {
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
                    identity.storage == workspace.storage,
                    "workspace {name:?} runner storage identity does not match the registry"
                );
                ensure!(
                    identity.proxy.url.starts_with("http://")
                        && !identity.proxy.url["http://".len()..].is_empty(),
                    "workspace {name:?} runner identity has an invalid proxy URL"
                );
            }
            ensure!(
                workspace.resources.memory_mi_b > 0,
                "workspace {name:?} has a zero memory limit"
            );
            ensure!(
                workspace.resources.cpu_quota_percent > 0,
                "workspace {name:?} has a zero CPU quota"
            );
            ensure!(
                !workspace.ssh.user.trim().is_empty(),
                "workspace {name:?} has an empty SSH user"
            );
            ensure!(
                !workspace.storage.image.trim().is_empty()
                    && !workspace.storage.image.contains('/')
                    && workspace.storage.image != "."
                    && workspace.storage.image != "..",
                "workspace {name:?} has an invalid project image name"
            );
            if let Some(host_key) = &workspace.ssh.known_host_key {
                ensure!(
                    !host_key.trim().is_empty(),
                    "workspace {name:?} has an empty SSH host key"
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

#[cfg(test)]
mod tests {
    use super::Registry;

    const VALID: &str = r#"
    {
      "version": 3,
      "workspaces": {
        "minimal": {
          "hostname": "minimal.vm",
          "runner": { "installable": "github:owner/project#runner" },
          "network": {
            "address": "10.100.0.10",
            "mac": "02:00:00:00:00:aa",
            "tap": "seter-minimal"
          },
          "resources": { "memoryMiB": 4096, "cpuQuotaPercent": 200 },
          "ssh": { "user": "seter", "knownHostKey": null },
          "storage": { "image": "minimal-project.img" }
        }
      }
    }
    "#;

    #[test]
    fn parses_version_three_registry() {
        let registry = Registry::from_reader(VALID.as_bytes()).unwrap();
        let workspace = registry.workspace("minimal").unwrap();

        assert_eq!(workspace.network.address.to_string(), "10.100.0.10");
        assert_eq!(workspace.runner.installable, "github:owner/project#runner");
        assert_eq!(workspace.resources.memory_mi_b, 4096);
        assert_eq!(workspace.resources.cpu_quota_percent, 200);
        assert_eq!(workspace.ssh.user, "seter");
        assert!(workspace.ssh.known_host_key.is_none());
    }

    #[test]
    fn parses_required_runner_identity() {
        let runner = r#""runner": {
            "installable": "github:owner/project#runner",
            "identity": {
              "version": 1,
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
              "storage": { "image": "minimal-project.img" }
            }
          }"#;
        let input = VALID.replacen(
            "\"runner\": { \"installable\": \"github:owner/project#runner\" }",
            runner,
            1,
        );
        let registry = Registry::from_reader(input.as_bytes()).unwrap();
        let identity = registry
            .workspace("minimal")
            .unwrap()
            .runner
            .identity
            .as_ref()
            .unwrap();
        assert_eq!(identity.workspace, "minimal");
        assert_eq!(identity.network.prefix_length, 24);
    }

    #[test]
    fn rejects_unsupported_version() {
        let input = VALID.replacen("\"version\": 3", "\"version\": 999", 1);
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error
            .to_string()
            .contains("unsupported workspace registry version"));
    }

    #[test]
    fn rejects_duplicate_addresses() {
        let second = r#"
        ,"other": {
          "hostname": "other.vm",
          "runner": { "installable": "github:owner/other#runner" },
          "network": {
            "address": "10.100.0.10",
            "mac": "02:00:00:00:00:11",
            "tap": "seter-other"
          },
          "resources": { "memoryMiB": 2048, "cpuQuotaPercent": 100 },
          "ssh": { "user": "seter", "knownHostKey": null },
          "storage": { "image": "other-project.img" }
        }
        "#;
        let input = VALID.replacen(
            "\n      }\n    }",
            &format!("{second}\n      }}\n    }}"),
            1,
        );
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error.to_string().contains("reuses IPv4 address"));
    }

    #[test]
    fn rejects_duplicate_macs_case_insensitively() {
        let second = r#"
        ,"other": {
          "hostname": "other.vm",
          "runner": { "installable": "github:owner/other#runner" },
          "network": {
            "address": "10.100.0.11",
            "mac": "02:00:00:00:00:AA",
            "tap": "seter-other"
          },
          "resources": { "memoryMiB": 2048, "cpuQuotaPercent": 100 },
          "ssh": { "user": "seter", "knownHostKey": null },
          "storage": { "image": "other-project.img" }
        }
        "#;
        let input = VALID.replacen(
            "\n      }\n    }",
            &format!("{second}\n      }}\n    }}"),
            1,
        );
        let error = Registry::from_reader(input.as_bytes()).unwrap_err();
        assert!(error.to_string().contains("reuses MAC address"));
    }

    #[test]
    fn reports_unknown_workspace() {
        let registry = Registry::from_reader(VALID.as_bytes()).unwrap();
        let error = registry.workspace("missing").unwrap_err();
        assert!(error.to_string().contains("is not configured"));
    }
}
