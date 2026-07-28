use std::{
    env,
    ffi::OsString,
    fs::{self, OpenOptions},
    io::{self, Write},
    net::{SocketAddr, TcpStream},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Output},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{bail, ensure, Context, Result};

use crate::registry::{Registry, RunnerIdentity, Workspace};

const RUNNER_IDENTITY_FILE: &str = "share/seter/identity.json";
const MAX_RUNNER_IDENTITY_BYTES: u64 = 64 * 1024;

const PROXY_CA_FILE: &str = "/var/lib/seter-proxy-public/seter-proxy-ca-cert.pem";
const KNOWN_HOSTS_ROOT: &str = "/var/lib/seter/known-hosts";
const SSH_WAIT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum State {
    NotBuilt,
    Stopped,
    Starting,
    Running,
    Stopping,
    Failed,
}

impl State {
    fn label(self) -> &'static str {
        match self {
            Self::NotBuilt => "not-deployed",
            Self::Stopped => "stopped",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Stopping => "stopping",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug)]
struct UnitState {
    active: String,
    sub: String,
    main_pid: u32,
}

pub fn up(name: &str) -> Result<i32> {
    if uses_test_state() || is_root()? {
        return start_workspace(name);
    }

    // Give the caller a useful error for typos before asking sudo. This is
    // only a usability check; the privileged half reloads and revalidates the
    // root-owned registry independently.
    Registry::load_default()?.workspace(name)?;
    run_elevated(&[OsString::from("__start"), OsString::from(name)])?;
    Ok(0)
}

pub fn start_workspace(name: &str) -> Result<i32> {
    enter_privileged_mode()?;
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let state = state_for(name, workspace)?;

    match state {
        State::Running | State::Starting => {
            println!(
                "{} is already {} at {}",
                name,
                state.label(),
                workspace.network.address
            );
            return Ok(0);
        }
        State::Stopping => bail!("workspace {name:?} is stopping"),
        State::Failed => {
            run_systemctl(["reset-failed", &vm_unit(name)])?;
        }
        State::NotBuilt => {
            bail!("workspace {name:?} has no host-deployed Runner; deploy the NixOS host configuration first")
        }
        State::Stopped => {}
    }

    // The Runner and registry are projections of one trusted NixOS
    // generation. Validate the immutable manifest before every cold start;
    // this performs no Nix evaluation or build.
    validate_runner(&workspace.runner.path, name, &workspace.runner.identity)?;

    run_systemctl(["start", &vm_unit(name)])?;
    let state = state_for(name, workspace)?;
    ensure!(
        matches!(state, State::Running | State::Starting),
        "workspace {name:?} did not start (state: {})",
        state.label()
    );
    println!("Started {name} at {}", workspace.network.address);
    Ok(0)
}

pub fn down(name: &str) -> Result<i32> {
    if uses_test_state() || is_root()? {
        return stop_workspace(name);
    }

    Registry::load_default()?.workspace(name)?;
    run_elevated(&[OsString::from("__stop"), OsString::from(name)])?;
    Ok(0)
}

pub fn stop_workspace(name: &str) -> Result<i32> {
    enter_privileged_mode()?;
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;

    if matches!(
        state_for(name, workspace)?,
        State::NotBuilt | State::Stopped
    ) {
        // Stopping the runtime target also cleans up plumbing left behind by a
        // previous failed launch.
        run_systemctl(["stop", &runtime_unit(name)])?;
        println!("{name} is already stopped");
        return Ok(0);
    }

    run_systemctl(["stop", &vm_unit(name)])?;
    run_systemctl(["stop", &runtime_unit(name)])?;
    let state = state_for(name, workspace)?;
    ensure!(
        matches!(state, State::Stopped | State::NotBuilt),
        "workspace {name:?} did not stop (state: {})",
        state.label()
    );
    println!("Stopped {name}");
    Ok(0)
}

pub fn status(name: Option<&str>) -> Result<i32> {
    let registry = Registry::load_default()?;

    if let Some(name) = name {
        let workspace = registry.workspace(name)?;
        let state = state_for(name, workspace)?;
        print_status(name, workspace, state, true)?;
        return Ok(if state == State::Running { 0 } else { 3 });
    }

    println!("{:<20} {:<11} {:<15} PID", "NAME", "STATE", "IP");
    for (name, workspace) in &registry.workspaces {
        print_status(name, workspace, state_for(name, workspace)?, false)?;
    }
    Ok(0)
}

pub fn shell(name: &str) -> Result<i32> {
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let state = state_for(name, workspace)?;
    ensure!(
        matches!(state, State::Running | State::Starting),
        "workspace {name:?} is {}; run `seter up {name}` first",
        state.label()
    );

    let host_key = workspace_host_key(name)?;
    validate_public_key(&host_key)?;
    wait_for_ssh(name, workspace)?;

    let known_hosts = TemporaryFile::new("known-hosts")?;
    fs::write(
        known_hosts.path(),
        format!("{} {}\n", workspace.network.address, host_key.trim()),
    )
    .context("failed to write temporary known_hosts file")?;

    let destination = format!("{}@{}", workspace.ssh.user, workspace.network.address);
    let status = command("SETER_SSH", "ssh")
        .arg("-o")
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
        .arg("-t")
        .arg(destination)
        .arg("--")
        .arg("cd /project && exec \"${SHELL:-/bin/sh}\" -l")
        .status()
        .context("failed to execute ssh")?;

    Ok(status.code().unwrap_or(255))
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

fn validate_runner(
    runner: &Path,
    workspace_name: &str,
    expected_identity: &RunnerIdentity,
) -> Result<()> {
    ensure!(runner.is_absolute(), "runner path must be absolute");
    if env::var_os("SETER_ALLOW_NON_STORE_RUNNER").is_none() {
        ensure!(
            runner.starts_with("/nix/store"),
            "runner {} is not in /nix/store",
            runner.display()
        );
    }
    for helper in ["microvm-run", "microvm-shutdown"] {
        let path = runner.join("bin").join(helper);
        ensure!(path.is_file(), "runner is missing {}", path.display());
        ensure!(
            path.metadata()?.permissions().mode() & 0o111 != 0,
            "runner helper {} is not executable",
            path.display()
        );
    }

    let identity_path = runner.join(RUNNER_IDENTITY_FILE);
    let metadata = fs::symlink_metadata(&identity_path).with_context(|| {
        format!(
            "runner for workspace {workspace_name:?} is missing required identity manifest {}",
            identity_path.display()
        )
    })?;
    ensure!(
        metadata.file_type().is_file(),
        "runner identity manifest {} must be a regular file",
        identity_path.display()
    );
    ensure!(
        metadata.len() <= MAX_RUNNER_IDENTITY_BYTES,
        "runner identity manifest {} exceeds {} bytes",
        identity_path.display(),
        MAX_RUNNER_IDENTITY_BYTES
    );
    let identity_file = fs::File::open(&identity_path).with_context(|| {
        format!(
            "failed to open runner identity manifest {}",
            identity_path.display()
        )
    })?;
    let actual: RunnerIdentity = serde_json::from_reader(identity_file).with_context(|| {
        format!(
            "runner identity manifest {} is invalid",
            identity_path.display()
        )
    })?;
    ensure!(
        &actual == expected_identity,
        "runner identity does not match workspace {workspace_name:?}\nexpected: {expected_identity:#?}\nfound: {actual:#?}"
    );
    Ok(())
}

fn state_for(name: &str, workspace: &Workspace) -> Result<State> {
    let unit = query_unit(name)?;
    Ok(classify_state(
        &unit.active,
        &unit.sub,
        workspace.runner.path.exists(),
    ))
}

fn classify_state(active: &str, _sub: &str, built: bool) -> State {
    match active {
        "active" => State::Running,
        "activating" => State::Starting,
        "deactivating" => State::Stopping,
        "failed" => State::Failed,
        _ if built => State::Stopped,
        _ => State::NotBuilt,
    }
}

fn query_unit(name: &str) -> Result<UnitState> {
    let output = command("SETER_SYSTEMCTL", "systemctl")
        .args([
            "show",
            &vm_unit(name),
            "--property=ActiveState",
            "--property=SubState",
            "--property=MainPID",
            "--no-pager",
        ])
        .output()
        .context("failed to query systemd")?;
    ensure_success("systemctl show", &output)?;
    let stdout = String::from_utf8(output.stdout).context("systemctl output was not UTF-8")?;
    let mut active = "inactive".to_owned();
    let mut sub = "dead".to_owned();
    let mut main_pid = 0;
    for line in stdout.lines() {
        if let Some(value) = line.strip_prefix("ActiveState=") {
            active = value.to_owned();
        } else if let Some(value) = line.strip_prefix("SubState=") {
            sub = value.to_owned();
        } else if let Some(value) = line.strip_prefix("MainPID=") {
            main_pid = value.parse().unwrap_or(0);
        }
    }
    Ok(UnitState {
        active,
        sub,
        main_pid,
    })
}

fn print_status(name: &str, workspace: &Workspace, state: State, verbose: bool) -> Result<()> {
    let unit = query_unit(name)?;
    let pid = if unit.main_pid == 0 {
        "-".to_owned()
    } else {
        unit.main_pid.to_string()
    };
    if verbose {
        println!("name:  {name}");
        println!("state: {}", state.label());
        println!("ip:    {}", workspace.network.address);
        println!("pid:   {pid}");
        if unit.sub != "dead" {
            println!("unit:  {}/{}", unit.active, unit.sub);
        }
    } else {
        println!(
            "{:<20} {:<11} {:<15} {}",
            name,
            state.label(),
            workspace.network.address,
            pid
        );
    }
    Ok(())
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

fn run_systemctl<const N: usize>(arguments: [&str; N]) -> Result<()> {
    let output = command("SETER_SYSTEMCTL", "systemctl")
        .args(arguments)
        .output()
        .context("failed to execute systemctl")?;
    ensure_success("systemctl", &output)
}

fn ensure_success(description: &str, output: &Output) -> Result<()> {
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    bail!(
        "{description} failed with {}{}",
        output.status,
        if stderr.trim().is_empty() {
            String::new()
        } else {
            format!(": {}", stderr.trim())
        }
    )
}

fn run_elevated(arguments: &[OsString]) -> Result<()> {
    // Wrapped Nix packages set this to the public wrapper path. Rust's
    // current_exe() sees the wrapper's private payload, which would not match
    // the exact command path authorized by the generated sudoers rules.
    let executable = match env::var_os("SETER_PRIVILEGED_HELPER") {
        Some(path) => PathBuf::from(path),
        None => env::current_exe().context("failed to locate the seter executable")?,
    };
    // NixOS exposes the setuid-root sudo entry point through /run/wrappers;
    // the immutable Nix store binary itself intentionally has no setuid bit.
    let output = command("SETER_SUDO", "/run/wrappers/bin/sudo")
        .arg("--")
        .arg(executable)
        .args(arguments)
        .output()
        .context("failed to invoke privileged Seter helper through sudo")?;
    if !output.stdout.is_empty() {
        std::io::stdout().write_all(&output.stdout)?;
    }
    if !output.stderr.is_empty() {
        std::io::stderr().write_all(&output.stderr)?;
    }
    ensure_success("privileged Seter helper", &output)
}

fn is_root() -> Result<bool> {
    let status = fs::read_to_string("/proc/self/status")
        .context("failed to read effective user ID from /proc/self/status")?;
    let effective = status
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|uids| uids.split_whitespace().nth(1))
        .context("/proc/self/status did not contain an effective user ID")?;
    Ok(effective == "0")
}

fn enter_privileged_mode() -> Result<()> {
    if !is_root()? {
        ensure!(uses_test_state(), "this internal command must run as root");
        return Ok(());
    }

    // The privileged half always uses host-owned configuration, paths and
    // executables. Environment overrides exist only for unprivileged tests
    // and must never turn a narrowly scoped sudo invocation into arbitrary
    // root command execution or filesystem writes.
    for variable in [
        "SETER_REGISTRY",
        "SETER_STATE_DIR",
        "SETER_TEST_MODE",
        "SETER_ALLOW_NON_STORE_RUNNER",
        "SETER_SYSTEMCTL",
        "SETER_DEBUGFS",
        "SETER_SSH_KEYGEN",
        "SETER_SSH",
        "SETER_SUDO",
        "SETER_PRIVILEGED_HELPER",
    ] {
        env::remove_var(variable);
    }
    Ok(())
}

fn command(variable: &str, default: &str) -> Command {
    Command::new(env::var_os(variable).unwrap_or_else(|| OsString::from(default)))
}

fn vm_unit(name: &str) -> String {
    format!("seter-vm-{name}.service")
}

fn runtime_unit(name: &str) -> String {
    format!("seter-runtime-{name}.target")
}

// Unprivileged tests run the privileged halves in-process against a private
// state directory. Both variables are required so that setting only a state
// directory can never silently skip real privilege separation, and both are
// discarded before any genuinely privileged work.
fn uses_test_state() -> bool {
    env::var_os("SETER_STATE_DIR").is_some() && env::var_os("SETER_TEST_MODE").is_some()
}

struct TemporaryFile(PathBuf);

impl TemporaryFile {
    fn new(label: &str) -> Result<Self> {
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

    fn path(&self) -> &Path {
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
    use super::{classify_state, State};

    #[test]
    fn classifies_systemd_and_build_state() {
        assert_eq!(classify_state("active", "running", true), State::Running);
        assert_eq!(classify_state("activating", "start", true), State::Starting);
        assert_eq!(
            classify_state("deactivating", "stop", true),
            State::Stopping
        );
        assert_eq!(classify_state("failed", "failed", true), State::Failed);
        assert_eq!(classify_state("inactive", "dead", true), State::Stopped);
        assert_eq!(classify_state("inactive", "dead", false), State::NotBuilt);
    }
}
