mod cli;
mod registry;

use std::io;

use anyhow::{bail, Result};
use clap::Parser;
use cli::{Cli, Command};
use tracing_subscriber::EnvFilter;

fn main() -> Result<()> {
    let cli = Cli::parse();
    init_tracing(cli.verbose);

    match cli.command {
        Command::List => {
            let registry = registry::Registry::load_default()?;
            for name in registry.workspaces.keys() {
                println!("{name}");
            }
            Ok(())
        }
        Command::Ip { workspace } => {
            let registry = registry::Registry::load_default()?;
            println!("{}", registry.workspace(&workspace)?.network.address);
            Ok(())
        }
        Command::Completions { shell } => {
            let shell: clap_complete::Shell = shell.into();
            clap_complete::generate(shell, &mut cli::command(), "seter", &mut io::stdout());
            Ok(())
        }
        command => bail!(
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
        Command::Up { .. } => "up",
        Command::Down { .. } => "down",
        Command::Run { .. } => "run",
        Command::Shell { .. } => "shell",
        Command::Status { .. } => "status",
        Command::List => "list",
        Command::Ip { .. } => "ip",
        Command::Update { .. } => "update",
        Command::Gc => "gc",
        Command::Completions { .. } => "completions",
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
