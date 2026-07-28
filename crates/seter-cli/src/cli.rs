use std::path::PathBuf;

use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
use clap_complete::Shell;

#[derive(Debug, Parser)]
#[command(name = "seter", version, about)]
pub struct Cli {
    /// Increase diagnostic output. Repeat for more detail.
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    pub verbose: u8,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Bootstrap a workspace from its approved HTTPS repository.
    Init { workspace: String },
    /// Start a workspace using its host-deployed Runner.
    Up { workspace: String },
    /// Gracefully stop a workspace.
    Down { workspace: String },
    /// Run a command through direnv in the registered checkout, starting when needed.
    Run {
        workspace: String,
        #[arg(last = true, required = true)]
        command: Vec<String>,
    },
    /// Open the registered checkout in an interactive shell, starting when needed.
    Shell { workspace: String },
    /// Show one workspace or all workspace statuses.
    Status { workspace: Option<String> },
    /// List configured workspaces.
    List,
    /// Print a workspace's IP address.
    Ip { workspace: String },
    /// Show grouped, workspace-scoped Policy Observations.
    Audit {
        workspace: String,
        /// Include observations no older than this duration (for example 30m or 2h).
        #[arg(long, default_value = "30m")]
        since: String,
        /// Reveal request paths, which may contain sensitive query parameters.
        #[arg(long)]
        paths: bool,
    },
    /// Review or reconcile the consumer-owned declarative Policy File.
    Policy {
        #[command(subcommand)]
        command: PolicyCommand,
    },
    /// Print the host-created Workspace SSH Identity public key.
    SshHostKey { workspace: String },
    /// Print the host proxy's public CA certificate for guest enrollment.
    ProxyCa,
    /// Replace selected reproducible state of a stopped workspace.
    Reset {
        workspace: String,
        #[arg(long)]
        home: bool,
        #[arg(long)]
        nix_store: bool,
        #[arg(long)]
        all_state: bool,
        /// Confirm non-interactively.
        #[arg(long)]
        yes: bool,
    },
    /// Permanently destroy a stopped workspace's Project Volume.
    DestroyProject {
        workspace: String,
        /// Confirm non-interactively after inspecting the retained state.
        #[arg(long)]
        yes: bool,
    },
    /// Remove GC roots belonging to retired workspaces.
    Gc,
    /// Generate shell completion code.
    Completions {
        #[arg(value_enum)]
        shell: CompletionShell,
    },
    /// Privileged half of `seter up`.
    #[command(name = "__start", hide = true)]
    StartWorkspace { workspace: String },
    /// Privileged half of `seter down`.
    #[command(name = "__stop", hide = true)]
    StopWorkspace { workspace: String },
    /// Privileged, workspace-scoped journal export used by `audit`.
    #[command(name = "__audit", hide = true)]
    ExportAudit { workspace: String },
    #[command(name = "__reset", hide = true)]
    ResetWorkspace {
        workspace: String,
        #[arg(long)]
        home: bool,
        #[arg(long)]
        nix_store: bool,
    },
    #[command(name = "__gc", hide = true)]
    CollectGarbage,
    #[command(name = "__destroy-project", hide = true)]
    DestroyProjectVolume { workspace: String },
}

#[derive(Debug, Subcommand)]
pub enum PolicyCommand {
    /// Interactively add exact grants or revoke existing grants.
    Review {
        workspace: String,
        #[arg(long)]
        file: PathBuf,
    },
    /// Compare the desired Policy File with the active host projection.
    Status {
        workspace: String,
        #[arg(long)]
        file: PathBuf,
    },
}

#[derive(Clone, Debug, ValueEnum)]
pub enum CompletionShell {
    Bash,
    Elvish,
    Fish,
    PowerShell,
    Zsh,
}

impl From<CompletionShell> for Shell {
    fn from(value: CompletionShell) -> Self {
        match value {
            CompletionShell::Bash => Shell::Bash,
            CompletionShell::Elvish => Shell::Elvish,
            CompletionShell::Fish => Shell::Fish,
            CompletionShell::PowerShell => Shell::PowerShell,
            CompletionShell::Zsh => Shell::Zsh,
        }
    }
}

pub fn command() -> clap::Command {
    Cli::command()
}
