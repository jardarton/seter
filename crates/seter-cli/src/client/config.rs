use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub version: u32,
    pub instance: String,
    pub flake: Option<String>,
    pub configuration: String,
    pub exchange_directory: Option<PathBuf>,
    pub exchange_mount: PathBuf,
    pub host_seter: String,
    pub forward_agent: bool,
    pub cdp_port: u16,
    pub cdp_port_file: Option<PathBuf>,
    pub docker_socket: PathBuf,
    pub herdr_config: Option<PathBuf>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            version: 1,
            instance: "seter".into(),
            flake: None,
            configuration: "seter-host".into(),
            exchange_directory: None,
            exchange_mount: "/workspace/seter-exchange".into(),
            host_seter: "/run/current-system/sw/bin/seter".into(),
            forward_agent: true,
            cdp_port: 9222,
            cdp_port_file: None,
            docker_socket: "/var/run/docker.sock".into(),
            herdr_config: None,
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let config = match fs::read_to_string(path) {
            Ok(contents) => toml::from_str(&contents)
                .with_context(|| format!("invalid client configuration {}", path.display()))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(error) => return Err(error).context("cannot read client configuration"),
        };
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1,
            "unsupported client configuration version"
        );
        validate_name(&self.instance)?;
        ensure!(
            !self.configuration.is_empty(),
            "configuration name is empty"
        );
        ensure!(
            !self.configuration.contains(['#', '\n', '\r', '\0']),
            "invalid NixOS configuration name"
        );
        ensure!(
            self.cdp_port >= 1024,
            "CDP port must be between 1024 and 65535"
        );
        ensure!(
            self.docker_socket.is_absolute()
                && !self
                    .docker_socket
                    .as_os_str()
                    .as_encoded_bytes()
                    .contains(&b':'),
            "Docker socket must be an absolute Host path without a colon"
        );
        ensure!(
            self.exchange_mount.is_absolute(),
            "exchange mount must be absolute"
        );
        ensure!(
            self.host_seter.starts_with('/') && !self.host_seter.contains('\0'),
            "host_seter must be an absolute executable path"
        );
        if let Some(path) = &self.exchange_directory {
            ensure!(path.is_absolute(), "exchange directory must be absolute");
            ensure!(
                path.is_dir(),
                "exchange directory must exist and be a directory"
            );
        }
        if let Some(flake) = &self.flake {
            ensure!(
                !flake.is_empty() && !flake.contains('#'),
                "flake must omit the configuration fragment"
            );
        }
        Ok(())
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        atomic_write(path, toml::to_string_pretty(self)?.as_bytes())
    }
}

pub fn validate_name(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 64
            && value.as_bytes()[0].is_ascii_alphanumeric()
            && value
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c)),
        "invalid instance name {value:?}"
    );
    Ok(())
}

pub fn home() -> Result<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is unset")
}

pub fn config_path(requested: Option<&Path>) -> Result<PathBuf> {
    let path = match requested {
        Some(path) => path.to_path_buf(),
        None => match env::var_os("SETER_CLIENT_CONFIG") {
            Some(path) => path.into(),
            None => env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .unwrap_or(home()?.join(".config"))
                .join("seter/client.toml"),
        },
    };
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(env::current_dir()?.join(path))
    }
}

pub fn private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_dir() && metadata.uid() == unsafe { libc::geteuid() },
        "client state directory must be owned by the current user: {}",
        path.display()
    );
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub fn atomic_write(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path.parent().context("file has no parent directory")?;
    fs::create_dir_all(parent)?;
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let temporary = parent.join(format!(".seter-{}-{nonce}", std::process::id()));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    let _ = fs::remove_file(&temporary);
    result.with_context(|| format!("cannot write {}", path.display()))
}

pub fn identifier(value: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in value {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configuration_rejects_invalid_transport_values() {
        for name in ["", "-option", "../escape", "space name", "$(command)"] {
            assert!(validate_name(name).is_err());
        }
        let config = Config {
            docker_socket: "relative/socket".into(),
            ..Config::default()
        };
        assert!(config.validate().is_err());
        assert!(toml::from_str::<Config>("instance = 'example'\nunknown = true").is_err());
    }
}
