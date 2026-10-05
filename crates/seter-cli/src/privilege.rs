//! Shared sudo command construction and root-only environment boundary.
use std::{env, path::PathBuf, process::Command};

use anyhow::{ensure, Context, Result};

pub(crate) fn elevated_command() -> Result<Command> {
    // current_exe() sees the Nix wrapper's private payload. Sudoers authorizes
    // the public wrapper, whose path is supplied by the packaged executable.
    let executable = match env::var_os("SETER_PRIVILEGED_HELPER") {
        Some(path) => PathBuf::from(path),
        None => env::current_exe().context("failed to locate the seter executable")?,
    };
    // NixOS's immutable store binary has no setuid bit; use its sudo wrapper.
    let mut command =
        Command::new(env::var_os("SETER_SUDO").unwrap_or_else(|| "/run/wrappers/bin/sudo".into()));
    command.arg("--").arg(executable);
    Ok(command)
}

pub(crate) fn is_root() -> bool {
    unsafe { libc::geteuid() == 0 }
}

pub(crate) fn enter_privileged_mode() -> Result<()> {
    ensure!(is_root(), "this internal command must run as root");

    // Privileged work always reloads host-owned configuration. Test overrides
    // must not let a narrowly scoped sudo command execute arbitrary programs
    // or write to caller-selected paths as root.
    for variable in [
        "SETER_REGISTRY",
        "SETER_STATE_DIR",
        "SETER_TEST_MODE",
        "SETER_ALLOW_NON_STORE_RUNNER",
        "SETER_SYSTEMCTL",
        "SETER_SSH_KEYGEN",
        "SETER_SSH",
        "SETER_SUDO",
        "SETER_PRIVILEGED_HELPER",
        "SETER_CLIENT_CONFIG",
        "SETER_HERDR_SSH_BRIDGE",
        "SETER_HERDR_REAL_SSH",
    ] {
        env::remove_var(variable);
    }
    Ok(())
}
