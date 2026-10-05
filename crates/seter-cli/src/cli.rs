use std::path::PathBuf;

use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
use clap_complete::Shell;

#[derive(Debug, Parser)]
#[command(name = "seter", version, about)]
pub struct Cli {
    #[arg(
        long,
        global = true,
        help = "Client connection configuration; selects the Lima backend"
    )]
    pub client_config: Option<PathBuf>,
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    #[command(about = "Access and manage the Seter Host")]
    Host {
        #[command(subcommand)]
        command: HostCommand,
    },
    #[command(name = "__client-probe", hide = true)]
    ClientProbe {
        #[arg(long, conflicts_with = "socket", required_unless_present = "socket")]
        port: Option<u16>,
        #[arg(long)]
        socket: Option<PathBuf>,
        #[arg(long, requires = "port")]
        websocket_path: Option<String>,
    },
    /// Bootstrap HTTPS repositories and verify local imports, or only --repo.
    Init {
        workspace: String,
        /// Repository key; omit to initialize every registered repository.
        #[arg(long)]
        repo: Option<String>,
    },
    /// Import a Git bundle into a registered local repository; never overwrite a checkout.
    Import {
        workspace: String,
        #[arg(long)]
        repo: Option<String>,
        #[arg(long)]
        bundle: PathBuf,
    },
    /// Start a workspace using its host-deployed Runner.
    Up { workspace: String },
    /// Gracefully stop a workspace.
    Down { workspace: String },
    /// Run a command through direnv in the selected checkout, starting when needed.
    Run {
        workspace: String,
        /// Repository key; otherwise use the default or sole repository.
        #[arg(long)]
        repo: Option<String>,
        #[arg(last = true, required = true)]
        command: Vec<String>,
    },
    /// Open the selected checkout (or --root) in a shell, starting when needed.
    Shell {
        workspace: String,
        /// Repository key; otherwise use the default or sole repository.
        #[arg(long, conflicts_with = "root")]
        repo: Option<String>,
        /// Open /project rather than a repository checkout.
        #[arg(long)]
        root: bool,
    },
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
    /// Remove retired public host-key projections, preserving all workspace storage.
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
pub enum HostCommand {
    #[command(about = "Configure a connection to an existing Lima instance")]
    Configure {
        #[arg(long)]
        lima: String,
        #[arg(long)]
        flake: Option<String>,
        #[arg(long)]
        configuration: Option<String>,
        #[arg(long)]
        host_seter: Option<PathBuf>,
        #[arg(long)]
        exchange_directory: Option<PathBuf>,
        #[arg(long)]
        exchange_mount: Option<PathBuf>,
        #[arg(long)]
        cdp_port_file: Option<PathBuf>,
        #[arg(long, value_parser = clap::value_parser!(u16).range(1024..))]
        cdp_port: Option<u16>,
        #[arg(long)]
        docker_socket: Option<PathBuf>,
        #[arg(long)]
        herdr_config: Option<PathBuf>,
        #[arg(long, action = clap::ArgAction::Set)]
        forward_agent: Option<bool>,
    },
    #[command(about = "Start the retained Host VM")]
    Start,
    #[command(about = "Gracefully stop Workspaces, connections, and the Host VM")]
    Stop,
    #[command(about = "Show Host and managed connection status")]
    Status,
    #[command(about = "Open a login shell directly on the Host")]
    Shell {
        #[arg(long)]
        cwd: Option<PathBuf>,
    },
    #[command(about = "Run a command directly on the Host")]
    Run {
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(last = true, required = true)]
        command: Vec<String>,
    },
    #[command(about = "Deploy the trusted consumer NixOS configuration")]
    Deploy {
        #[arg(long)]
        flake: Option<String>,
        #[arg(long)]
        configuration: Option<String>,
        #[arg(long, value_parser = clap::value_parser!(u32).range(1..))]
        max_jobs: Option<u32>,
        #[arg(long, value_parser = clap::value_parser!(u32).range(1..))]
        cores: Option<u32>,
    },
    #[command(about = "Connect the Host to a macOS Chrome CDP endpoint")]
    Browser {
        #[command(subcommand)]
        command: BrowserCommand,
    },
    #[command(about = "Access the Host Docker daemon through a private socket")]
    Docker {
        #[command(subcommand)]
        command: DockerCommand,
    },
    #[command(about = "Attach a local Herdr client to the Host server")]
    Herdr,
    #[command(about = "Manage loopback-only service forwards")]
    Forward {
        #[command(subcommand)]
        command: ForwardCommand,
    },
}

#[derive(Debug, Subcommand)]
pub enum BrowserCommand {
    #[command(about = "Forward an existing Chrome CDP endpoint into Host loopback")]
    Attach {
        #[arg(long)]
        port_file: Option<PathBuf>,
        #[arg(long, value_parser = clap::value_parser!(u16).range(1024..))]
        port: Option<u16>,
    },
    #[command(about = "Close the managed CDP connection and remove its endpoint file")]
    Detach,
    #[command(about = "Check browser identity and forwarded endpoint reachability")]
    Status,
}

#[derive(Debug, Subcommand)]
pub enum DockerCommand {
    #[command(about = "Connect the Docker socket and print a DOCKER_HOST export")]
    Env,
    #[command(about = "Connect the Docker socket and create or update a Docker context")]
    Context {
        #[arg(long)]
        name: Option<String>,
        #[arg(long = "use")]
        select: bool,
    },
    #[command(about = "Check the forwarded Docker API")]
    Status,
    #[command(about = "Close the managed Docker socket connection")]
    Disconnect,
}

#[derive(Debug, Subcommand)]
pub enum ForwardCommand {
    #[command(about = "Forward a Host loopback service to Client loopback")]
    Start {
        #[arg(value_parser = clap::value_parser!(u16).range(1..))]
        port: u16,
        #[arg(long, value_parser = clap::value_parser!(u16).range(1024..))]
        local_port: Option<u16>,
        #[arg(long)]
        open: bool,
    },
    #[command(about = "List managed service forwards")]
    List,
    #[command(about = "Close the forward using this Client port")]
    Stop {
        #[arg(value_parser = clap::value_parser!(u16).range(1024..))]
        local_port: u16,
    },
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_selection_and_root_are_explicit() {
        assert!(Cli::try_parse_from(["seter", "init", "product", "--repo", "backend"]).is_ok());
        assert!(Cli::try_parse_from(["seter", "shell", "product", "--root"]).is_ok());
        assert!(
            Cli::try_parse_from(["seter", "shell", "product", "--root", "--repo", "backend"])
                .is_err()
        );
        let cli = Cli::try_parse_from([
            "seter", "run", "product", "--repo", "backend", "--", "echo", "--repo", "literal",
        ])
        .unwrap();
        let Command::Run { repo, command, .. } = cli.command else {
            panic!("expected run")
        };
        assert_eq!(repo.as_deref(), Some("backend"));
        assert_eq!(command, ["echo", "--repo", "literal"]);
    }
}
