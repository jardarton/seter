use std::{
    env,
    ffi::OsString,
    fs::{self, OpenOptions},
    io::{self, IsTerminal, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Output},
};

use anyhow::{bail, ensure, Context, Result};
use fs2::FileExt;

use crate::registry::{Registry, Repository, RunnerIdentity, Workspace};

mod privilege;
mod ssh;
use privilege::{delegate_or_run, enter_privileged_mode, uses_test_state};
pub use ssh::{proxy_ca, ssh_host_key};
use ssh::{shell_quote, SshSession};

const RUNNER_IDENTITY_FILE: &str = "share/seter/identity.json";
const MAX_RUNNER_IDENTITY_BYTES: u64 = 64 * 1024;

const BOOTSTRAP_SCRIPT: &str = include_str!("lifecycle/bootstrap.sh");

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

pub fn init(name: &str, requested: Option<&str>) -> Result<i32> {
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let selected: Vec<(&str, &Repository)> = if requested.is_some() {
        vec![workspace.select_repository(requested)?]
    } else {
        workspace
            .repositories
            .iter()
            .map(|(key, repo)| (key.as_str(), repo))
            .collect()
    };

    ensure!(
        workspace.runner.path.exists(),
        "workspace {name:?} has no host-deployed Runner; deploy the NixOS host configuration first"
    );

    // Starting the immutable Runner creates any missing persistent volume
    // images. It deliberately remains running whether bootstrap succeeds or
    // fails so the operator can inspect a rejected partial checkout.
    up(name)?;

    let ssh = SshSession::connect(name, workspace)?;
    let mut failed = false;
    for (repository_name, repository) in selected {
        eprintln!("seter init: {name}/{repository_name}");
        let status = ssh
            .command(false)
            .arg("--")
            .arg(bootstrap_remote_command(repository))
            .status()
            .context("failed to execute ssh for Workspace Bootstrap")?;
        if !status.success() {
            eprintln!(
                "seter init: {name}/{repository_name} failed (exit {}); retained all working data",
                status.code().unwrap_or(255)
            );
            failed = true;
        }
    }
    Ok(if failed { 1 } else { 0 })
}

fn bootstrap_remote_command(repository: &Repository) -> String {
    let placeholder = repository
        .credential
        .as_ref()
        .map(|credential| credential.placeholder.as_str())
        .unwrap_or("");
    format!(
        "sh -c {} seter-bootstrap {} {} {} {}",
        shell_quote(BOOTSTRAP_SCRIPT),
        shell_quote(&repository.url),
        shell_quote(&checkout_path(repository)),
        shell_quote(repository.branch.as_deref().unwrap_or("")),
        shell_quote(placeholder),
    )
}

pub fn up(name: &str) -> Result<i32> {
    delegate_or_run(
        Some(name),
        &[OsString::from("__start"), OsString::from(name)],
        || start_workspace(name),
    )
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
    delegate_or_run(
        Some(name),
        &[OsString::from("__stop"), OsString::from(name)],
        || stop_workspace(name),
    )
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
    let mut arguments = vec![OsString::from("__reset"), OsString::from(name)];
    if home {
        arguments.push(OsString::from("--home"));
    }
    if nix_store {
        arguments.push(OsString::from("--nix-store"));
    }
    delegate_or_run(None, &arguments, || reset_workspace(name, home, nix_store))
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
    let _lock = acquire_lifecycle_lock(name)?;
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
        "WARNING: destroying the Project Volume deletes ALL repository checkouts in this workspace and may destroy dirty or unpushed Git work; its offline image cannot be inspected safely."
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
    delegate_or_run(
        None,
        &[OsString::from("__destroy-project"), OsString::from(name)],
        || destroy_project_volume(name),
    )
}

pub fn destroy_project_volume(name: &str) -> Result<i32> {
    enter_privileged_mode()?;
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let root = state_directory(name);
    let _lock = acquire_lifecycle_lock(name)?;
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
    delegate_or_run(None, &[OsString::from("__gc")], collect_garbage)
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

pub fn shell(name: &str, requested: Option<&str>, root: bool) -> Result<i32> {
    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    ensure!(
        !root || requested.is_none(),
        "--root cannot be combined with --repo"
    );
    let selected = if root {
        None
    } else {
        Some(workspace.select_repository(requested)?)
    };
    let checkout = selected
        .map(|(_, repository)| checkout_path(repository))
        .unwrap_or_else(|| "/project".to_owned());
    ensure_running(name, workspace)?;

    let ssh = SshSession::connect(name, workspace)?;
    if let Some((key, _)) = selected {
        explain_direnv(name, key);
    }
    let status = ssh.command(true)
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

pub fn run(name: &str, requested: Option<&str>, arguments: &[String]) -> Result<i32> {
    ensure!(!arguments.is_empty(), "seter run requires a command");

    let registry = Registry::load_default()?;
    let workspace = registry.workspace(name)?;
    let (key, repository) = workspace.select_repository(requested)?;
    ensure_running(name, workspace)?;

    let ssh = SshSession::connect(name, workspace)?;
    let remote_command = run_remote_command(name, &checkout_path(repository), arguments);
    explain_direnv(name, key);
    let status = ssh
        .command(false)
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

fn checkout_path(repository: &Repository) -> String {
    format!("/project/{}", repository.checkout_name)
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

fn explain_direnv(name: &str, repository: &str) {
    eprintln!(
        "seter: repository code is never approved automatically; review .envrc and run `direnv allow` in `seter shell {name} --repo {repository}`"
    );
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

fn acquire_lifecycle_lock(name: &str) -> Result<fs::File> {
    let lock_path = lifecycle_lock(name);
    acquire_lock(name, &lock_path)
}

fn acquire_lock(name: &str, lock_path: &Path) -> Result<fs::File> {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o640)
        .open(lock_path)
        .with_context(|| format!("failed to open lifecycle lock {}", lock_path.display()))?;
    lock.try_lock_exclusive()
        .with_context(|| format!("workspace {name:?} lifecycle is busy"))?;
    Ok(lock)
}

#[cfg(test)]
mod tests {
    use std::{fs, time::SystemTime};

    use super::{acquire_lock, classify_state, run_remote_command, shell_quote, State};

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

    #[test]
    fn acquired_lifecycle_lock_is_held_by_returned_file() {
        let directory = std::env::temp_dir().join(format!(
            "seter-lock-test-{}-{:?}",
            std::process::id(),
            SystemTime::now()
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("lifecycle.lock");

        let held = acquire_lock("example", &path).unwrap();
        assert!(acquire_lock("example", &path).is_err());
        drop(held);
        acquire_lock("example", &path).unwrap();

        fs::remove_dir_all(directory).unwrap();
    }
}
