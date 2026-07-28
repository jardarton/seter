mod audit;
mod cli;
mod lifecycle;
mod policy;
mod registry;

use std::{io, process::ExitCode};

use anyhow::Result;
use clap::Parser;
use cli::{Cli, Command, PolicyCommand};
use tracing_subscriber::EnvFilter;

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code.clamp(0, 255) as u8),
        Err(error) => {
            eprintln!("seter: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<i32> {
    let cli = Cli::parse();
    init_tracing(cli.verbose);

    match cli.command {
        Command::List => {
            let registry = registry::Registry::load_default()?;
            for name in registry.workspaces.keys() {
                println!("{name}");
            }
            Ok(0)
        }
        Command::Ip { workspace } => {
            let registry = registry::Registry::load_default()?;
            println!("{}", registry.workspace(&workspace)?.network.address);
            Ok(0)
        }
        Command::Audit {
            workspace,
            since,
            paths,
        } => audit::show(&workspace, &since, paths),
        Command::Policy { command } => match command {
            PolicyCommand::Review { workspace, file } => policy::review(&workspace, &file),
            PolicyCommand::Status { workspace, file } => policy::status(&workspace, &file),
        },
        Command::Init { workspace } => lifecycle::init(&workspace),
        Command::Up { workspace } => lifecycle::up(&workspace),
        Command::Down { workspace } => lifecycle::down(&workspace),
        Command::Run { workspace, command } => lifecycle::run(&workspace, &command),
        Command::Status { workspace } => lifecycle::status(workspace.as_deref()),
        Command::Shell { workspace } => lifecycle::shell(&workspace),
        Command::SshHostKey { workspace } => lifecycle::ssh_host_key(&workspace),
        Command::ProxyCa => lifecycle::proxy_ca(),
        Command::StartWorkspace { workspace } => lifecycle::start_workspace(&workspace),
        Command::StopWorkspace { workspace } => lifecycle::stop_workspace(&workspace),
        Command::ExportAudit { workspace } => audit::privileged_export(&workspace),
        Command::Completions { shell } => {
            let shell: clap_complete::Shell = shell.into();
            clap_complete::generate(shell, &mut cli::command(), "seter", &mut io::stdout());
            Ok(0)
        }
        command => anyhow::bail!(
            "{} is scaffolded but not implemented yet",
            command_name(&command)
        ),
    }
}

fn init_tracing(verbose: u8) {
    let fallback = match verbose {
        0 => "warn",
        1 => "info",
        _ => "debug",
    };

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| fallback.into()))
        .with_writer(io::stderr)
        .init();
}

fn command_name(command: &Command) -> &'static str {
    match command {
        Command::Init { .. } => "init",
        Command::Up { .. } => "up",
        Command::Down { .. } => "down",
        Command::Run { .. } => "run",
        Command::Shell { .. } => "shell",
        Command::Status { .. } => "status",
        Command::List => "list",
        Command::Ip { .. } => "ip",
        Command::Audit { .. } => "audit",
        Command::Policy { .. } => "policy",
        Command::SshHostKey { .. } => "ssh-host-key",
        Command::ProxyCa => "proxy-ca",
        Command::Gc => "gc",
        Command::Completions { .. } => "completions",
        Command::StartWorkspace { .. } => "__start",
        Command::StopWorkspace { .. } => "__stop",
        Command::ExportAudit { .. } => "__audit",
    }
}

#[cfg(test)]
mod tests {
    use clap::CommandFactory;

    use crate::cli::Cli;

    #[test]
    fn clap_definition_is_valid() {
        Cli::command().debug_assert();
    }
}
