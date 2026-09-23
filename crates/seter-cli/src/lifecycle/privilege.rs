//! Sudo delegation and privileged-environment boundary for lifecycle operations.
use std::{env, ffi::OsString, fs, io::Write, path::PathBuf};

use anyhow::{ensure, Context, Result};

use super::{command, ensure_success, Registry};

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

pub(super) fn delegate_or_run(
    workspace: Option<&str>,
    arguments: &[OsString],
    privileged: impl FnOnce() -> Result<i32>,
) -> Result<i32> {
    if uses_test_state() || is_root()? {
        return privileged();
    }
    // Catch typos before sudo; the privileged handler independently reloads
    // and validates the root-owned registry after elevation.
    if let Some(name) = workspace {
        Registry::load_default()?.workspace(name)?;
    }
    run_elevated(arguments)?;
    Ok(0)
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

pub(super) fn enter_privileged_mode() -> Result<()> {
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

// Unprivileged tests run the privileged halves in-process against a private
// state directory. Both variables are required so that setting only a state
// directory can never silently skip real privilege separation, and both are
// discarded before any genuinely privileged work.
pub(super) fn uses_test_state() -> bool {
    env::var_os("SETER_STATE_DIR").is_some() && env::var_os("SETER_TEST_MODE").is_some()
}
