use std::{
    env,
    ffi::OsString,
    fs::{self, OpenOptions},
    io::{self, Write},
    net::{SocketAddr, TcpStream},
    os::{
        fd::AsRawFd,
        raw::c_int,
        unix::fs::{symlink, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::{Command, Output},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{bail, ensure, Context, Result};

use crate::registry::{Registry, RunnerIdentity, Workspace};

const RUNNER_IDENTITY_FILE: &str = "share/seter/identity.json";
const MAX_RUNNER_IDENTITY_BYTES: u64 = 64 * 1024;

const STATE_ROOT: &str = "/var/lib/seter/workspaces";
const GCROOT_ROOT: &str = "/nix/var/nix/gcroots/per-project";
const LOCK_ROOT: &str = "/run/lock/seter";
const PROXY_CA_FILE: &str = "/var/lib/seter-proxy-public/seter-proxy-ca-cert.pem";
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
            Self::NotBuilt => "not-built",
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

pub fn update(name: &str) -> Result<i32> {
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;

    ensure_update_allowed(name)?;
    let runner = build_runner(&workspace.runner.installable)?;
    validate_runner(&runner, name, workspace.runner.identity.as_ref())?;

    if uses_test_state() || is_root()? {
        install_runner_path(name, &runner)?;
    } else {
        run_elevated(&[
            OsString::from("__install-runner"),
            OsString::from(name),
            runner.as_os_str().to_owned(),
        ])?;
    }

    println!("Updated {name} to {}", runner.display());
    Ok(0)
}

pub fn install_runner(name: &str, runner: &Path) -> Result<i32> {
    enter_privileged_mode()?;
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    ensure_update_allowed(name)?;
    let runner = runner
        .canonicalize()
        .with_context(|| format!("failed to resolve runner {}", runner.display()))?;
    validate_runner(&runner, name, workspace.runner.identity.as_ref())?;
    install_runner_path(name, &runner)?;
    Ok(0)
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
    let state = state_for(name)?;

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
            bail!("workspace {name:?} has no installed runner; run `seter update {name}` first")
        }
        State::Stopped => {}
    }

    // Host configuration may have changed since the last update. Recheck the
    // installed immutable runner before every cold start so stale identity
    // cannot silently turn into a disconnected or misaddressed guest.
    let installed = state_root()
        .join(name)
        .join("current")
        .canonicalize()
        .with_context(|| format!("workspace {name:?} has no valid installed runner"))?;
    validate_runner(&installed, name, workspace.runner.identity.as_ref())?;

    run_systemctl(["start", &vm_unit(name)])?;
    let state = state_for(name)?;
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
    registry.workspace(name)?;

    if matches!(state_for(name)?, State::NotBuilt | State::Stopped) {
        // Stopping the runtime target also cleans up plumbing left behind by a
        // previous failed launch.
        run_systemctl(["stop", &runtime_unit(name)])?;
        println!("{name} is already stopped");
        return Ok(0);
    }

    run_systemctl(["stop", &vm_unit(name)])?;
    run_systemctl(["stop", &runtime_unit(name)])?;
    let state = state_for(name)?;
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
        let state = state_for(name)?;
        print_status(name, workspace, state, true)?;
        return Ok(if state == State::Running { 0 } else { 3 });
    }

    println!("{:<20} {:<11} {:<15} PID", "NAME", "STATE", "IP");
    for (name, workspace) in &registry.workspaces {
        print_status(name, workspace, state_for(name)?, false)?;
    }
    Ok(0)
}

pub fn shell(name: &str) -> Result<i32> {
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let state = state_for(name)?;
    ensure!(
        matches!(state, State::Running | State::Starting),
        "workspace {name:?} is {}; run `seter up {name}` first",
        state.label()
    );

    let host_key = workspace.ssh.known_host_key.as_deref().with_context(|| {
        format!(
            "workspace {name:?} has no pinned SSH host key; after its first boot and shutdown, run `seter ssh-host-key {name}`"
        )
    })?;
    validate_public_key(host_key)?;
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
    ensure!(
        !matches!(
            state_for(name)?,
            State::Running | State::Starting | State::Stopping
        ),
        "workspace {name:?} must be stopped before reading its project image"
    );

    if uses_test_state() || is_root()? {
        read_host_key(name)
    } else {
        run_elevated(&[OsString::from("__read-host-key"), OsString::from(name)])?;
        Ok(0)
    }
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

pub fn read_host_key(name: &str) -> Result<i32> {
    enter_privileged_mode()?;
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let state_dir = state_root().join(name);
    let _lifecycle_lock = LifecycleLock::acquire(&lifecycle_lock_path(name))?;
    ensure!(
        !matches!(
            state_for(name)?,
            State::Running | State::Starting | State::Stopping
        ),
        "workspace {name:?} must be stopped before reading its project image"
    );

    let image = state_dir.join(&workspace.storage.image);
    ensure!(
        image.is_file(),
        "project image {} does not exist; boot the workspace once, then shut it down",
        image.display()
    );

    let output = command("SETER_DEBUGFS", "debugfs")
        .arg("-R")
        .arg("cat /.seter-state/ssh/ssh_host_ed25519_key.pub")
        .arg(&image)
        .output()
        .with_context(|| format!("failed to read SSH host key from {}", image.display()))?;
    ensure_success("debugfs", &output)?;
    let key = String::from_utf8(output.stdout).context("SSH host key was not UTF-8")?;
    let key = key.trim();
    validate_public_key(key).context("project image contained an invalid SSH host public key")?;

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
    eprintln!("Add this value as the workspace's `knownHostKey` after verifying the fingerprint.");
    Ok(0)
}

fn build_runner(installable: &str) -> Result<PathBuf> {
    let output = command("SETER_NIX", "nix")
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "build",
            "--no-link",
            "--print-out-paths",
            "--",
        ])
        .arg(installable)
        .output()
        .with_context(|| format!("failed to build runner installable {installable:?}"))?;
    ensure_success("nix build", &output)?;

    let stdout = String::from_utf8(output.stdout).context("nix build output was not UTF-8")?;
    let paths: Vec<_> = stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    ensure!(
        paths.len() == 1,
        "runner installable produced {} outputs; expected exactly one",
        paths.len()
    );
    Ok(PathBuf::from(paths[0]))
}

fn validate_runner(
    runner: &Path,
    workspace_name: &str,
    expected_identity: Option<&RunnerIdentity>,
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

    if let Some(expected) = expected_identity {
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
            &actual == expected,
            "runner identity does not match workspace {workspace_name:?}\nexpected: {expected:#?}\nfound: {actual:#?}"
        );
    }
    Ok(())
}

fn install_runner_path(name: &str, runner: &Path) -> Result<()> {
    let state_dir = state_root().join(name);
    let gcroot_dir = gcroot_root();
    let history_dir = gcroot_dir.join(".runner-history").join(name);
    fs::create_dir_all(&state_dir)
        .with_context(|| format!("failed to create {}", state_dir.display()))?;
    fs::create_dir_all(&gcroot_dir)
        .with_context(|| format!("failed to create {}", gcroot_dir.display()))?;
    fs::create_dir_all(&history_dir)
        .with_context(|| format!("failed to create {}", history_dir.display()))?;
    let _lifecycle_lock = LifecycleLock::acquire(&lifecycle_lock_path(name))?;

    // Persistent guest Nix databases retain registrations for every system
    // closure they have booted. Keep those immutable runner generations (and
    // therefore their read-only lower-store closures) available on the host.
    // Matching guest roots retain booted closure registrations, while normal
    // guest GC is disabled because it cannot distinguish unrelated lower
    // paths. History cleanup must be coordinated with resetting the
    // workspace's private Nix image.
    let runner_name = runner
        .file_name()
        .context("runner path has no store-path name")?;
    atomic_symlink(runner, &history_dir.join(runner_name)).with_context(|| {
        format!(
            "failed to retain runner {} in workspace {:?} history",
            runner.display(),
            name
        )
    })?;

    // Keep both runners rooted throughout the switch. If publishing `current`
    // fails, the old permanent root remains intact. If promoting the pending
    // root fails, leave it behind so the newly published runner stays rooted.
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let pending_gcroot = gcroot_dir.join(format!(".{name}.pending-{}-{nonce}", std::process::id()));
    symlink(runner, &pending_gcroot).with_context(|| {
        format!(
            "failed to create pending GC root {} -> {}",
            pending_gcroot.display(),
            runner.display()
        )
    })?;

    if let Err(error) = atomic_symlink(runner, &state_dir.join("current")) {
        let _ = fs::remove_file(&pending_gcroot);
        return Err(error);
    }

    fs::rename(&pending_gcroot, gcroot_dir.join(name)).with_context(|| {
        format!(
            "failed to promote pending GC root {}; it was retained to protect the installed runner",
            pending_gcroot.display()
        )
    })?;
    Ok(())
}

struct LifecycleLock(fs::File);

impl LifecycleLock {
    fn acquire(path: &Path) -> Result<Self> {
        let mut options = OpenOptions::new();
        options.read(true).write(true).truncate(false);
        // Production locks are provisioned by tmpfiles under a root-owned
        // directory so the workspace account cannot replace them. Isolated
        // tests use disposable state directories and create their own lock.
        if uses_test_state() {
            options.create(true).mode(0o600);
        }
        let file = options
            .open(path)
            .with_context(|| format!("failed to open lifecycle lock {}", path.display()))?;
        // SAFETY: flock only inspects the valid file descriptor and integer
        // operation flags supplied here. The descriptor remains owned by
        // this value for at least as long as the lock.
        let result = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            bail!(
                "workspace lifecycle is busy (could not lock {}: {error})",
                path.display()
            );
        }
        Ok(Self(file))
    }
}

impl Drop for LifecycleLock {
    fn drop(&mut self) {
        // SAFETY: the descriptor is still valid while Drop runs. Unlocking
        // is best effort because closing the descriptor releases it anyway.
        unsafe {
            flock(self.0.as_raw_fd(), LOCK_UN);
        }
    }
}

const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
const LOCK_UN: c_int = 8;

unsafe extern "C" {
    fn flock(fd: c_int, operation: c_int) -> c_int;
}

fn atomic_symlink(target: &Path, destination: &Path) -> Result<()> {
    let parent = destination
        .parent()
        .context("symlink destination has no parent")?;
    let file_name = destination
        .file_name()
        .context("symlink destination has no file name")?
        .to_string_lossy();
    let temporary = parent.join(format!(".{file_name}.new-{}", std::process::id()));
    let _ = fs::remove_file(&temporary);
    symlink(target, &temporary).with_context(|| {
        format!(
            "failed to create temporary symlink {} -> {}",
            temporary.display(),
            target.display()
        )
    })?;
    fs::rename(&temporary, destination).with_context(|| {
        format!(
            "failed to atomically install symlink {} -> {}",
            destination.display(),
            target.display()
        )
    })?;
    Ok(())
}

fn ensure_update_allowed(name: &str) -> Result<()> {
    let state = state_for(name)?;
    ensure!(
        !matches!(state, State::Running | State::Starting | State::Stopping),
        "workspace {name:?} is {}; stop it before updating",
        state.label()
    );
    Ok(())
}

fn state_for(name: &str) -> Result<State> {
    let unit = query_unit(name)?;
    Ok(classify_state(
        &unit.active,
        &unit.sub,
        gcroot_root().join(name).exists(),
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
        let state = state_for(name)?;
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
        "SETER_GCROOT_DIR",
        "SETER_ALLOW_NON_STORE_RUNNER",
        "SETER_SYSTEMCTL",
        "SETER_DEBUGFS",
        "SETER_SSH_KEYGEN",
        "SETER_NIX",
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

fn state_root() -> PathBuf {
    env::var_os("SETER_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(STATE_ROOT))
}

fn gcroot_root() -> PathBuf {
    env::var_os("SETER_GCROOT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(GCROOT_ROOT))
}

fn lifecycle_lock_path(name: &str) -> PathBuf {
    if uses_test_state() {
        state_root().join(name).join("lifecycle.lock")
    } else {
        PathBuf::from(LOCK_ROOT).join(format!("{name}.lock"))
    }
}

fn uses_test_state() -> bool {
    env::var_os("SETER_STATE_DIR").is_some() && env::var_os("SETER_GCROOT_DIR").is_some()
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
