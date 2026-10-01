//! Sudo delegation and privileged-environment boundary for lifecycle operations.
use std::{env, ffi::OsString, io::Write};

use anyhow::{Context, Result};

use super::{ensure_success, Registry};
use crate::privilege::{elevated_command, is_root};

fn run_elevated(arguments: &[OsString]) -> Result<()> {
    let output = elevated_command()?
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
    if uses_test_state() || is_root() {
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

pub(super) fn enter_privileged_mode() -> Result<()> {
    if !is_root() && uses_test_state() {
        return Ok(());
    }
    crate::privilege::enter_privileged_mode()
}

// Unprivileged tests run the privileged halves in-process against a private
// state directory. Both variables are required so that setting only a state
// directory can never silently skip real privilege separation, and both are
// discarded before any genuinely privileged work.
pub(super) fn uses_test_state() -> bool {
    env::var_os("SETER_STATE_DIR").is_some() && env::var_os("SETER_TEST_MODE").is_some()
}
