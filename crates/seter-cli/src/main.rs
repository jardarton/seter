mod audit;
mod cli;
mod client;
mod host_patterns;
mod lifecycle;
mod policy;
mod privilege;
mod registry;

use std::{io, process::ExitCode};

use anyhow::Result;
use clap::Parser;
use cli::{Cli, Command, PolicyCommand};

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
    if let Some(code) = client::herdr_bridge()? {
        return Ok(code);
    }
    let cli = Cli::parse();

    if let Command::Host { command } = &cli.command {
        return client::host(command, cli.client_config.as_deref());
    }
    if let Command::ClientProbe {
        port,
        socket,
        websocket_path,
    } = &cli.command
    {
        return client::probe_endpoint(*port, socket.as_deref(), websocket_path.as_deref());
    }
    let internal = matches!(
        cli.command,
        Command::StartWorkspace { .. }
            | Command::StopWorkspace { .. }
            | Command::ExportAudit { .. }
            | Command::ResetWorkspace { .. }
            | Command::CollectGarbage
            | Command::DestroyProjectVolume { .. }
    );
    if !internal
        && !matches!(cli.command, Command::Completions { .. })
        && client::enabled(cli.client_config.as_deref())
    {
        return client::workspace(&cli.command, cli.client_config.as_deref());
    }

    match cli.command {
        Command::Host { .. } | Command::ClientProbe { .. } => unreachable!(),
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
        Command::Init { workspace, repo } => lifecycle::init(&workspace, repo.as_deref()),
        Command::Import {
            workspace,
            repo,
            bundle,
        } => lifecycle::import(&workspace, repo.as_deref(), &bundle),
        Command::Up { workspace } => lifecycle::up(&workspace),
        Command::Down { workspace } => lifecycle::down(&workspace),
        Command::Run {
            workspace,
            repo,
            command,
        } => lifecycle::run(&workspace, repo.as_deref(), &command),
        Command::Status { workspace } => lifecycle::status(workspace.as_deref()),
        Command::Shell {
            workspace,
            repo,
            root,
        } => lifecycle::shell(&workspace, repo.as_deref(), root),
        Command::SshHostKey { workspace } => lifecycle::ssh_host_key(&workspace),
        Command::ProxyCa => lifecycle::proxy_ca(),
        Command::Reset {
            workspace,
            home,
            nix_store,
            all_state,
            yes,
        } => lifecycle::reset(&workspace, home || all_state, nix_store || all_state, yes),
        Command::DestroyProject { workspace, yes } => lifecycle::destroy_project(&workspace, yes),
        Command::ResetWorkspace {
            workspace,
            home,
            nix_store,
        } => lifecycle::reset_workspace(&workspace, home, nix_store),
        Command::Gc => lifecycle::gc(),
        Command::CollectGarbage => lifecycle::collect_garbage(),
        Command::DestroyProjectVolume { workspace } => {
            lifecycle::destroy_project_volume(&workspace)
        }
        Command::StartWorkspace { workspace } => lifecycle::start_workspace(&workspace),
        Command::StopWorkspace { workspace } => lifecycle::stop_workspace(&workspace),
        Command::ExportAudit { workspace } => audit::privileged_export(&workspace),
        Command::Completions { shell } => {
            let shell: clap_complete::Shell = shell.into();
            clap_complete::generate(shell, &mut cli::command(), "seter", &mut io::stdout());
            Ok(0)
        }
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
