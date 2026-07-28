use std::{
    env,
    ffi::OsString,
    fs::{self, OpenOptions},
    io::{self, IsTerminal, Write},
    net::{SocketAddr, TcpStream},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Output},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{bail, ensure, Context, Result};
use fs2::FileExt;

use crate::registry::{Registry, RunnerIdentity, Workspace};

const RUNNER_IDENTITY_FILE: &str = "share/seter/identity.json";
const MAX_RUNNER_IDENTITY_BYTES: u64 = 64 * 1024;

const PROXY_CA_FILE: &str = "/var/lib/seter-proxy-public/seter-proxy-ca-cert.pem";
const KNOWN_HOSTS_ROOT: &str = "/var/lib/seter/known-hosts";
const SSH_WAIT: Duration = Duration::from_secs(30);

const BOOTSTRAP_SCRIPT: &str = r#"
set -eu

url=$1
target=$2
branch=$3
placeholder=$4
marker=${target%/*}/.seter-bootstrap-${target##*/}

fail() {
    printf 'seter init: %s\n' "$1" >&2
    exit 20
}

configure_credential() {
    if test -n "$placeholder"; then
        git -C "$target" config --local "http.$url.extraHeader" "Authorization: $placeholder"
    fi
}

ensure_marker() {
    if test -L "$marker" || { test -e "$marker" && ! test -d "$marker"; }; then
        fail "bootstrap marker $marker is not a directory; refusing to overwrite it"
    fi
    if test -d "$marker" && test -n "$(find "$marker" -mindepth 1 -maxdepth 1 -print -quit)"; then
        fail "bootstrap marker $marker contains unrelated content; refusing to overwrite it"
    fi
    if ! test -d "$marker"; then
        mkdir -- "$marker"
    fi
}

clone_repository() {
    ensure_marker
    if test -n "$placeholder"; then
        if test -n "$branch"; then
            git -c "http.$url.extraHeader=Authorization: $placeholder" clone --origin origin --branch "$branch" -- "$url" "$target"
        else
            git -c "http.$url.extraHeader=Authorization: $placeholder" clone --origin origin -- "$url" "$target"
        fi
    elif test -n "$branch"; then
        git clone --origin origin --branch "$branch" -- "$url" "$target"
    else
        git clone --origin origin -- "$url" "$target"
    fi
    rmdir -- "$marker"
    configure_credential
}

if test -L "$target"; then
    fail "checkout path $target is a symbolic link; refusing to overwrite it"
fi

if ! test -e "$target"; then
    clone_repository
    printf 'Initialized repository at %s\n' "$target"
    exit 0
fi

if ! test -d "$target"; then
    fail "checkout path $target is not a directory; refusing to overwrite it"
fi

if test -L "$target/.git"; then
    fail "checkout path $target has a symbolic-link .git directory; refusing to alter it"
fi

if ! test -e "$target/.git"; then
    if test -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)"; then
        fail "checkout path $target contains unrelated content; move it aside or choose a different checkout name"
    fi
    clone_repository
    printf 'Initialized repository at %s\n' "$target"
    exit 0
fi

if ! test -d "$target/.git"; then
    fail "checkout path $target has an unsupported .git file; refusing to alter it"
fi

actual_url=$(git -C "$target" remote get-url origin 2>/dev/null || true)
if test "$actual_url" != "$url"; then
    fail "checkout path $target has origin $actual_url, expected $url; refusing to alter it"
fi

recover_empty_worktree=false
if git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
    if test -d "$marker"; then
        if test -z "$(git -C "$target" status --porcelain)"; then
            rmdir -- "$marker"
            configure_credential
            printf 'Workspace repository is already initialized at %s\n' "$target"
            exit 0
        fi
        if test -z "$(find "$target" -mindepth 1 -maxdepth 1 ! -name .git -print -quit)"; then
            # Seter left its marker and no working files exist, so it is safe
            # to reconstruct the index and working tree from the fetched HEAD.
            recover_empty_worktree=true
        else
            fail "checkout path $target is a partial repository with working data; refusing to overwrite it"
        fi
    else
        configure_credential
        printf 'Workspace repository is already initialized at %s\n' "$target"
        exit 0
    fi
fi

# A repository with no checked-out commit is recoverable only while no working
# data exists. Never fetch, checkout, clean, reset, or otherwise mutate a
# partial bootstrap that contains anything except Seter's clone metadata.
if test -n "$(find "$target" -mindepth 1 -maxdepth 1 ! -name .git -print -quit)"; then
    fail "checkout path $target is a partial repository with working data; refusing to overwrite it"
fi

ensure_marker
configure_credential
git -C "$target" fetch origin
if test -n "$branch"; then
    git -C "$target" show-ref --verify --quiet "refs/remotes/origin/$branch" \
        || fail "configured branch $branch does not exist on the approved repository"
    if git -C "$target" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$target" checkout "$branch"
    else
        git -C "$target" checkout --track -b "$branch" "origin/$branch"
    fi
else
    git -C "$target" remote set-head origin --auto >/dev/null
    default_ref=$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) \
        || fail "approved repository does not advertise a default branch"
    default_branch=${default_ref#refs/remotes/origin/}
    if git -C "$target" show-ref --verify --quiet "refs/heads/$default_branch"; then
        git -C "$target" checkout "$default_branch"
    else
        git -C "$target" checkout --track -b "$default_branch" "$default_ref"
    fi
fi

if test "$recover_empty_worktree" = true; then
    git -C "$target" read-tree HEAD
    git -C "$target" checkout-index --all
fi

rmdir -- "$marker"
printf 'Recovered and initialized repository at %s\n' "$target"
"#;

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

pub fn init(name: &str) -> Result<i32> {
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;

    ensure!(
        workspace.runner.path.exists(),
        "workspace {name:?} has no host-deployed Runner; deploy the NixOS host configuration first"
    );

    // Starting the immutable Runner creates any missing persistent volume
    // images. It deliberately remains running whether bootstrap succeeds or
    // fails so the operator can inspect a rejected partial checkout.
    up(name)?;

    let host_key = workspace_host_key(name)?;
    validate_public_key(&host_key)?;
    wait_for_ssh(name, workspace)?;
    let known_hosts = temporary_known_hosts(workspace, &host_key)?;

    let destination = format!("{}@{}", workspace.ssh.user, workspace.network.address);
    let target = format!("/project/{}", workspace.repository.checkout_name);
    let branch = workspace.repository.branch.as_deref().unwrap_or("");
    let placeholder = workspace
        .repository
        .credential
        .as_ref()
        .map(|credential| credential.placeholder.as_str())
        .unwrap_or("");
    let remote_command = format!(
        "sh -c {} seter-bootstrap {} {} {} {}",
        shell_quote(BOOTSTRAP_SCRIPT),
        shell_quote(&workspace.repository.url),
        shell_quote(&target),
        shell_quote(branch),
        shell_quote(placeholder),
    );

    let status = ssh_command(&known_hosts)
        .arg(&destination)
        .arg("--")
        .arg(remote_command)
        .status()
        .context("failed to execute ssh for Workspace Bootstrap")?;
    Ok(status.code().unwrap_or(255))
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

pub fn reset(name: &str, home: bool, nix_store: bool, yes: bool) -> Result<i32> {
    ensure!(
        home || nix_store,
        "select --home, --nix-store, or --all-state"
    );
    Registry::load_default()?.workspace(name)?;
    let labels = match (home, nix_store) {
        (true, true) => "Home and private Nix-store volumes",
        (true, false) => "Home Volume",
        (false, true) => "private Nix-store volume",
        _ => unreachable!(),
    };
    println!("Reset {labels} for {name}. The Project Volume will be preserved.");
    if !yes {
        ensure!(
            io::stdin().is_terminal(),
            "non-interactive reset requires --yes"
        );
        print!("Type the workspace name to continue: ");
        io::stdout().flush()?;
        let mut answer = String::new();
        io::stdin().read_line(&mut answer)?;
        ensure!(answer.trim() == name, "reset cancelled");
    }
    if uses_test_state() || is_root()? {
        return reset_workspace(name, home, nix_store);
    }
    let mut arguments = vec![OsString::from("__reset"), OsString::from(name)];
    if home {
        arguments.push(OsString::from("--home"));
    }
    if nix_store {
        arguments.push(OsString::from("--nix-store"));
    }
    run_elevated(&arguments)?;
    Ok(0)
}

pub fn reset_workspace(name: &str, home: bool, nix_store: bool) -> Result<i32> {
    enter_privileged_mode()?;
    ensure!(home || nix_store, "no reset storage selected");
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    ensure!(
        state_for(name, workspace)? == State::Stopped,
        "workspace {name:?} must be stopped before reset"
    );

    let root = state_directory(name);
    fs::create_dir_all(&root)
        .with_context(|| format!("failed to open workspace state {}", root.display()))?;
    let lock_path = lifecycle_lock(name);
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o640)
        .open(&lock_path)
        .with_context(|| format!("failed to open lifecycle lock {}", lock_path.display()))?;
    lock.try_lock_exclusive()
        .with_context(|| format!("workspace {name:?} lifecycle is busy"))?;
    // Recheck under the same lock held for the VM lifetime, closing the start/reset race.
    ensure!(
        state_for(name, workspace)? == State::Stopped,
        "workspace {name:?} must be stopped before reset"
    );
    let mut removed = Vec::new();
    for (selected, label, image) in [
        (home, "Home", &workspace.storage.home.image),
        (
            nix_store,
            "private Nix store",
            &workspace.storage.nix_store.image,
        ),
    ] {
        if selected {
            let path = root.join(image);
            match fs::remove_file(&path) {
                Ok(()) => removed.push(label),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("failed to reset {}", path.display()))
                }
            }
        }
    }
    println!(
        "Reset {} for {name}; Project Volume preserved",
        if removed.is_empty() {
            "selected absent state".into()
        } else {
            removed.join(" and ")
        }
    );
    Ok(0)
}

pub fn destroy_project(name: &str, yes: bool) -> Result<i32> {
    let registry = Registry::load_default()?;
    registry.workspace(name)?;
    eprintln!(
        "WARNING: the Project Volume may contain dirty or unpushed Git work; its offline image cannot be inspected safely."
    );
    eprintln!("This permanently destroys all working data for workspace {name}.");
    if !yes {
        ensure!(
            io::stdin().is_terminal(),
            "non-interactive destruction requires --yes"
        );
        print!("Type 'destroy {name}' to continue: ");
        io::stdout().flush()?;
        let mut answer = String::new();
        io::stdin().read_line(&mut answer)?;
        ensure!(
            answer.trim() == format!("destroy {name}"),
            "destruction cancelled"
        );
    }
    if uses_test_state() || is_root()? {
        return destroy_project_volume(name);
    }
    run_elevated(&[OsString::from("__destroy-project"), OsString::from(name)])?;
    Ok(0)
}

pub fn destroy_project_volume(name: &str) -> Result<i32> {
    enter_privileged_mode()?;
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let root = state_directory(name);
    let lock_path = lifecycle_lock(name);
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o640)
        .open(&lock_path)
        .with_context(|| format!("failed to open lifecycle lock {}", lock_path.display()))?;
    lock.try_lock_exclusive()
        .with_context(|| format!("workspace {name:?} lifecycle is busy"))?;
    ensure!(
        state_for(name, workspace)? == State::Stopped,
        "workspace {name:?} must be stopped before Project Volume destruction"
    );
    let project = root.join(&workspace.storage.project.image);
    fs::remove_file(&project)
        .with_context(|| format!("failed to destroy Project Volume {}", project.display()))?;
    println!("Destroyed Project Volume for {name}");
    Ok(0)
}

pub fn gc() -> Result<i32> {
    if uses_test_state() || is_root()? {
        return collect_garbage();
    }
    run_elevated(&[OsString::from("__gc")])?;
    Ok(0)
}

pub fn collect_garbage() -> Result<i32> {
    enter_privileged_mode()?;
    let registry = Registry::load_default()?;
    let root = state_root();
    if !root.exists() {
        return Ok(0);
    }
    for entry in
        fs::read_dir(&root).with_context(|| format!("failed to inspect {}", root.display()))?
    {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !registry.workspaces.contains_key(&name) {
                println!("Retained orphaned state for retired workspace {name}: {} (Project Volume is never garbage-collected)", entry.path().display());
            }
        }
    }
    // Known-host projections contain only the public half of the preserved
    // identity and are recreated by deployment. They are therefore safe to
    // remove after retirement; identities and volume directories are not.
    let known_hosts = if uses_test_state() {
        state_root().join(".known-hosts")
    } else {
        PathBuf::from("/var/lib/seter/known-hosts")
    };
    if known_hosts.exists() {
        for entry in fs::read_dir(&known_hosts)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !registry.workspaces.contains_key(&name) && entry.file_type()?.is_file() {
                fs::remove_file(entry.path()).with_context(|| {
                    format!("failed to remove retired known-host projection {name:?}")
                })?;
                println!("Removed replaceable known-host projection for retired workspace {name}");
            }
        }
    }
    println!(
        "Garbage collection complete; active Runner roots and all workspace volumes were preserved"
    );
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
    ensure_running(name, workspace)?;

    let host_key = workspace_host_key(name)?;
    validate_public_key(&host_key)?;
    wait_for_ssh(name, workspace)?;

    let known_hosts = temporary_known_hosts(workspace, &host_key)?;

    let destination = format!("{}@{}", workspace.ssh.user, workspace.network.address);
    let checkout = checkout_path(workspace);
    explain_direnv(name);
    let status = ssh_command(&known_hosts)
        .arg("-t")
        .arg(&destination)
        .arg("--")
        .arg(format!(
            "cd {} || {{ printf 'seter shell: registered checkout is missing; run seter init %s\\n' {} >&2; exit 72; }}; exec \"${{SHELL:-/bin/sh}}\" -l",
            shell_quote(&checkout),
            shell_quote(name),
        ))
        .status()
        .context("failed to execute ssh")?;

    Ok(status.code().unwrap_or(255))
}

pub fn run(name: &str, arguments: &[String]) -> Result<i32> {
    ensure!(!arguments.is_empty(), "seter run requires a command");

    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    ensure_running(name, workspace)?;

    let host_key = workspace_host_key(name)?;
    validate_public_key(&host_key)?;
    wait_for_ssh(name, workspace)?;
    let known_hosts = temporary_known_hosts(workspace, &host_key)?;

    let destination = format!("{}@{}", workspace.ssh.user, workspace.network.address);
    let remote_command = run_remote_command(name, &checkout_path(workspace), arguments);
    explain_direnv(name);
    let status = ssh_command(&known_hosts)
        .arg(&destination)
        .arg("--")
        .arg(remote_command)
        .status()
        .context("failed to execute ssh")?;

    Ok(status.code().unwrap_or(255))
}

fn ensure_running(name: &str, workspace: &Workspace) -> Result<()> {
    match state_for(name, workspace)? {
        State::Running | State::Starting => Ok(()),
        State::Stopping => bail!("workspace {name:?} is stopping"),
        _ => {
            up(name)?;
            Ok(())
        }
    }
}

fn checkout_path(workspace: &Workspace) -> String {
    format!("/project/{}", workspace.repository.checkout_name)
}

fn run_remote_command(name: &str, checkout: &str, arguments: &[String]) -> String {
    let command = arguments
        .iter()
        .map(|argument| shell_quote(argument))
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "cd {} || {{ printf 'seter run: registered checkout is missing; run seter init %s\\n' {} >&2; exit 72; }}; exec direnv exec . {}",
        shell_quote(checkout),
        shell_quote(name),
        command,
    )
}

fn explain_direnv(name: &str) {
    eprintln!(
        "seter: repository code is never approved automatically; review .envrc and run `direnv allow` in `seter shell {name}`"
    );
}

fn temporary_known_hosts(workspace: &Workspace, host_key: &str) -> Result<TemporaryFile> {
    let known_hosts = TemporaryFile::new("known-hosts")?;
    fs::write(
        known_hosts.path(),
        format!("{} {}\n", workspace.network.address, host_key.trim()),
    )
    .context("failed to write temporary known_hosts file")?;
    Ok(known_hosts)
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

fn shell_quote(value: &str) -> String {
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

fn state_root() -> PathBuf {
    if uses_test_state() {
        PathBuf::from(env::var_os("SETER_STATE_DIR").unwrap())
    } else {
        PathBuf::from("/var/lib/seter/workspaces")
    }
}

fn state_directory(name: &str) -> PathBuf {
    state_root().join(name)
}

fn lifecycle_lock(name: &str) -> PathBuf {
    if uses_test_state() {
        state_root().join(format!(".{name}.lock"))
    } else {
        PathBuf::from(format!("/run/lock/seter/{name}.lock"))
    }
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
    use super::{classify_state, run_remote_command, shell_quote, State};

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

    #[test]
    fn quotes_remote_shell_data_without_interpolation() {
        assert_eq!(shell_quote("plain"), "'plain'");
        assert_eq!(
            shell_quote("a'b; $(touch nope)"),
            "'a'\\''b; $(touch nope)'"
        );
    }

    #[test]
    fn run_command_enters_checkout_and_preserves_argument_boundaries() {
        assert_eq!(
            run_remote_command(
                "minimal",
                "/project/project",
                &["printf".into(), "%s\\n".into(), "a'b; $(touch nope)".into()]
            ),
            "cd '/project/project' || { printf 'seter run: registered checkout is missing; run seter init %s\\n' 'minimal' >&2; exit 72; }; exec direnv exec . 'printf' '%s\\n' 'a'\\''b; $(touch nope)'"
        );
    }
}
