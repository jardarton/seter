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
    /// Start a workspace using its host-deployed Runner.
    Up { workspace: String },
    /// Gracefully stop a workspace.
    Down { workspace: String },
    /// Run a command in a workspace, starting it when needed.
    Run {
        workspace: String,
        #[arg(last = true, required = true)]
        command: Vec<String>,
    },
    /// Open an interactive shell in a workspace.
    Shell { workspace: String },
    /// Show one workspace or all workspace statuses.
    Status { workspace: Option<String> },
    /// List configured workspaces.
    List,
    /// Print a workspace's IP address.
    Ip { workspace: String },
    /// Print the host-created Workspace SSH Identity public key.
    SshHostKey { workspace: String },
    /// Print the host proxy's public CA certificate for guest enrollment.
    ProxyCa,
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
