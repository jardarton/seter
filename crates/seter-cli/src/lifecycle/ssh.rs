//! Workspace SSH connectivity, host-created identity, and public CA inspection.
use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, Write},
    net::{SocketAddr, TcpStream},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{bail, ensure, Context, Result};

use super::{command, ensure_success, state_for, Registry, State, Workspace};

const PROXY_CA_FILE: &str = "/var/lib/seter-proxy-public/seter-proxy-ca-cert.pem";
const KNOWN_HOSTS_ROOT: &str = "/var/lib/seter/known-hosts";
const SSH_WAIT: Duration = Duration::from_secs(30);

fn temporary_known_hosts(workspace: &Workspace, host_key: &str) -> Result<TemporaryFile> {
    let known_hosts = TemporaryFile::new("known-hosts")?;
    fs::write(
        known_hosts.path(),
        format!("{} {}\n", workspace.network.address, host_key.trim()),
    )
    .context("failed to write temporary known_hosts file")?;
    Ok(known_hosts)
}

pub(super) struct SshSession {
    known_hosts: TemporaryFile,
    destination: String,
}

impl SshSession {
    pub(super) fn connect(name: &str, workspace: &Workspace) -> Result<Self> {
        let host_key = workspace_host_key(name)?;
        validate_public_key(&host_key)?;
        wait_for_ssh(name, workspace)?;
        let known_hosts = temporary_known_hosts(workspace, &host_key)?;
        let destination = format!("{}@{}", workspace.ssh.user, workspace.network.address);
        Ok(Self {
            known_hosts,
            destination,
        })
    }

    pub(super) fn command(&self, tty: bool) -> Command {
        let mut command = ssh_command(&self.known_hosts);
        if tty {
            command.arg("-t");
        }
        command.arg(&self.destination);
        command
    }
}

fn ssh_command(known_hosts: &TemporaryFile) -> Command {
    let mut ssh = command("SETER_SSH", "ssh");
    ssh.arg("-o")
        .arg("StrictHostKeyChecking=yes")
        .arg("-o")
        .arg(format!(
            "UserKnownHostsFile={}",
            known_hosts.path().display()
        ))
        .arg("-o")
        .arg("GlobalKnownHostsFile=/dev/null")
        .arg("-o")
        .arg("ForwardAgent=no")
        .arg("-o")
        .arg("ForwardX11=no")
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg("ConnectTimeout=10")
        .arg("-o")
        .arg("ConnectionAttempts=1")
        .arg("-o")
        .arg("ServerAliveInterval=5")
        .arg("-o")
        .arg("ServerAliveCountMax=2");
    ssh
}

pub(super) fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn ssh_host_key(name: &str) -> Result<i32> {
    let registry = Registry::load_default()?;
    registry.workspace(name)?;
    print_host_key(&workspace_host_key(name)?)
}

pub fn proxy_ca() -> Result<i32> {
    let path = env::var_os("SETER_PROXY_CA_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(PROXY_CA_FILE));
    let metadata = fs::symlink_metadata(&path).with_context(|| {
        format!(
            "cannot read the proxy CA at {}; ensure seter-proxy.service has started",
            path.display()
        )
    })?;
    ensure!(
        metadata.file_type().is_file(),
        "proxy CA path {} is not a regular file",
        path.display()
    );

    let certificate = fs::read(&path)
        .with_context(|| format!("failed to read proxy CA certificate {}", path.display()))?;
    ensure!(
        !certificate
            .windows(b"PRIVATE KEY".len())
            .any(|window| window == b"PRIVATE KEY"),
        "refusing to print proxy CA file containing private key material"
    );

    let fingerprint = command("SETER_OPENSSL", "openssl")
        .args(["x509", "-in"])
        .arg(&path)
        .args(["-noout", "-fingerprint", "-sha256"])
        .output()
        .context("failed to execute openssl while validating the proxy CA")?;
    ensure!(
        fingerprint.status.success(),
        "proxy CA certificate is invalid: {}",
        String::from_utf8_lossy(&fingerprint.stderr).trim()
    );

    io::stdout()
        .write_all(&certificate)
        .context("failed to print proxy CA certificate")?;
    eprintln!("{}", String::from_utf8_lossy(&fingerprint.stdout).trim());
    Ok(0)
}

fn workspace_host_key(name: &str) -> Result<String> {
    let root = env::var_os("SETER_KNOWN_HOSTS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(KNOWN_HOSTS_ROOT));
    let path = root.join(name);
    match fs::read_to_string(&path) {
        Ok(key) => {
            let key = key.trim().to_owned();
            validate_public_key(&key).with_context(|| {
                format!("host-created Workspace SSH Identity at {} is invalid", path.display())
            })?;
            Ok(key)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => bail!(
            "workspace {name:?} has no host-created Workspace SSH Identity at {}; redeploy the NixOS host configuration",
            path.display()
        ),
        Err(error) => Err(error).with_context(|| {
            format!("failed to read Workspace SSH Identity public key {}", path.display())
        }),
    }
}

fn print_host_key(key: &str) -> Result<i32> {
    validate_public_key(key)?;

    let key_file = TemporaryFile::new("host-key")?;
    fs::write(key_file.path(), format!("{key}\n"))?;
    let fingerprint = command("SETER_SSH_KEYGEN", "ssh-keygen")
        .arg("-l")
        .arg("-f")
        .arg(key_file.path())
        .output()
        .context("failed to execute ssh-keygen")?;
    ensure_success("ssh-keygen", &fingerprint)?;

    println!("{key}");
    eprintln!("{}", String::from_utf8_lossy(&fingerprint.stdout).trim());
    Ok(0)
}

fn wait_for_ssh(name: &str, workspace: &Workspace) -> Result<()> {
    let address = SocketAddr::from((workspace.network.address, 22));
    let deadline = Instant::now() + SSH_WAIT;
    while Instant::now() < deadline {
        if TcpStream::connect_timeout(&address, Duration::from_millis(500)).is_ok() {
            return Ok(());
        }
        let state = state_for(name, workspace)?;
        ensure!(
            matches!(state, State::Running | State::Starting),
            "workspace {name:?} stopped while waiting for SSH"
        );
        thread::sleep(Duration::from_millis(500));
    }
    bail!(
        "timed out after {}s waiting for SSH at {address}",
        SSH_WAIT.as_secs()
    )
}

fn validate_public_key(key: &str) -> Result<()> {
    let mut fields = key.split_whitespace();
    let kind = fields.next().context("SSH public key has no key type")?;
    let body = fields.next().context("SSH public key has no key data")?;
    ensure!(
        kind.starts_with("ssh-") || kind.starts_with("ecdsa-") || kind.starts_with("sk-"),
        "unsupported SSH public key type {kind:?}"
    );
    ensure!(!body.is_empty(), "SSH public key has empty key data");
    Ok(())
}

pub(super) struct TemporaryFile(PathBuf);

impl TemporaryFile {
    pub(super) fn new(label: &str) -> Result<Self> {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let path = env::temp_dir().join(format!("seter-{label}-{}-{nonce}", std::process::id()));
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("failed to create temporary file {}", path.display()))?;
        Ok(Self(path))
    }

    pub(super) fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TemporaryFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::{SshSession, TemporaryFile};

    #[test]
    fn session_owns_host_file_and_places_destination_after_options() {
        let known_hosts = TemporaryFile::new("ssh-session-test").unwrap();
        let known_hosts_path = known_hosts.path().to_owned();
        let session = SshSession {
            known_hosts,
            destination: "seter@192.0.2.2".to_owned(),
        };
        let command = session.command(true);
        let arguments = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();

        assert_eq!(arguments[arguments.len() - 2..], ["-t", "seter@192.0.2.2"]);
        assert!(arguments.contains(&format!(
            "UserKnownHostsFile={}",
            known_hosts_path.display()
        )));
        drop(session);
        assert!(!known_hosts_path.exists());
    }
}
