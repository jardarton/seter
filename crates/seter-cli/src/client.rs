use std::{
    env,
    fs::{self, File},
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    process::{Command as Process, Stdio},
};

use anyhow::{bail, ensure, Context, Result};

use crate::cli::{
    BrowserCommand, Command, DockerCommand, ForwardCommand, HostCommand, PolicyCommand,
};

mod config;
mod connections;
mod probe;
mod transport;

use transport::{ensure_output, exec, interactive, quote, status, Client};

pub fn enabled(path: Option<&Path>) -> bool {
    cfg!(target_os = "macos") || path.is_some() || env::var_os("SETER_CLIENT_CONFIG").is_some()
}

pub fn probe_endpoint(
    port: Option<u16>,
    socket: Option<&Path>,
    expected_path: Option<&str>,
) -> Result<i32> {
    match (port, socket) {
        (Some(port), None) => {
            probe::browser(port, expected_path)?;
        }
        (None, Some(socket)) => probe::docker(socket)?,
        _ => bail!("select exactly one endpoint"),
    }
    Ok(0)
}

pub fn host(command: &HostCommand, path: Option<&Path>) -> Result<i32> {
    if !enabled(path) {
        return local_host(command);
    }
    let mut client = Client::load(path)?;
    match command {
        HostCommand::Configure {
            lima,
            flake,
            configuration,
            host_seter,
            exchange_directory,
            exchange_mount,
            cdp_port_file,
            cdp_port,
            docker_socket,
            herdr_config,
            forward_agent,
        } => {
            let _lock = client.lock()?;
            for connection in client.connections()? {
                ensure!(
                    !client.connection_alive(&connection)?,
                    "disconnect managed connections before changing client configuration"
                );
                client.stop_connection(&connection)?;
            }
            config::validate_name(lima)?;
            client.config.instance.clone_from(lima);
            if let Some(flake) = flake {
                client.config.flake = Some(resolve_flake(flake)?);
            }
            if let Some(configuration) = configuration {
                client.config.configuration.clone_from(configuration);
            }
            if let Some(executable) = host_seter {
                client.config.host_seter = executable
                    .to_str()
                    .context("Host executable path must be UTF-8")?
                    .into();
            }
            if let Some(directory) = exchange_directory {
                client.config.exchange_directory =
                    Some(fs::canonicalize(directory).context("exchange directory must exist")?);
            }
            if let Some(mount) = exchange_mount {
                client.config.exchange_mount.clone_from(mount);
            }
            if let Some(file) = cdp_port_file {
                client.config.cdp_port_file =
                    Some(fs::canonicalize(file).context("CDP endpoint file must exist")?);
            }
            if let Some(port) = cdp_port {
                client.config.cdp_port = *port;
            }
            if let Some(socket) = docker_socket {
                client.config.docker_socket.clone_from(socket);
            }
            if let Some(file) = herdr_config {
                client.config.herdr_config =
                    Some(fs::canonicalize(file).context("Herdr configuration must exist")?);
            }
            if let Some(agent) = forward_agent {
                client.config.forward_agent = *agent;
            }
            client.config.validate()?;
            client.lima_value("Status")?;
            client.config.save(&client.config_path)?;
            println!(
                "Configured Host {} in {}",
                client.config.instance,
                client.config_path.display()
            );
            Ok(0)
        }
        HostCommand::Start => client.start(),
        HostCommand::Stop => stop(&client),
        HostCommand::Status => host_status(&client),
        HostCommand::Shell { cwd } => {
            client.ensure_running()?;
            exec(&mut client.remote_command(
                &client.host_script(None, cwd.as_deref())?,
                interactive(),
                true,
            )?)
        }
        HostCommand::Run { cwd, command } => {
            client.ensure_running()?;
            let script = client.host_script(Some(command), cwd.as_deref())?;
            let script = format!("exec \"${{SHELL:-/bin/sh}}\" -lc {}", quote(&script));
            exec(&mut client.remote_command(&script, false, true)?)
        }
        HostCommand::Deploy {
            flake,
            configuration,
            max_jobs,
            cores,
        } => {
            client.ensure_running()?;
            let flake =
                deployment_flake(&client.config, flake.as_deref(), configuration.as_deref())?;
            let endpoint = client.endpoint()?;
            let mut command = Process::new("nixos-rebuild");
            command.args([
                "--no-reexec",
                "switch",
                "--flake",
                &flake,
                "--build-host",
                &endpoint.destination,
                "--target-host",
                &endpoint.destination,
                "--elevate",
                "sudo",
            ]);
            build_limits(&mut command, *max_jobs, *cores);
            let options = format!(
                "-F {} -o ControlMaster=no -o ControlPath=none -o ForwardAgent=no",
                quote(
                    endpoint
                        .ssh_config
                        .to_str()
                        .context("SSH configuration path must be UTF-8")?
                )
            );
            let previous = env::var("NIX_SSHOPTS").unwrap_or_default();
            command.env("NIX_SSHOPTS", format!("{options} {previous}"));
            exec(&mut command)
        }
        HostCommand::Browser { command } => match command {
            BrowserCommand::Attach { port_file, port } => {
                client.browser_attach(port_file.as_deref(), *port)
            }
            BrowserCommand::Detach => client.browser_detach(),
            BrowserCommand::Status => client.browser_status(),
        },
        HostCommand::Docker { command } => match command {
            DockerCommand::Env => {
                let socket = client.docker_connect()?;
                println!(
                    "export DOCKER_HOST={}",
                    quote(&format!("unix://{}", socket.display()))
                );
                Ok(0)
            }
            DockerCommand::Context { name, select } => {
                docker_context(&client, name.as_deref(), *select)
            }
            DockerCommand::Status => client.docker_status(),
            DockerCommand::Disconnect => client.docker_disconnect(),
        },
        HostCommand::Herdr => herdr(&client),
        HostCommand::Forward { command } => match command {
            ForwardCommand::Start {
                port,
                local_port,
                open,
            } => client.forward_start(*port, *local_port, *open),
            ForwardCommand::List => client.forward_list(),
            ForwardCommand::Stop { local_port } => client.forward_stop(*local_port),
        },
    }
}

fn local_host(command: &HostCommand) -> Result<i32> {
    match command {
        HostCommand::Shell { cwd } => {
            let mut command = Process::new(transport::shell());
            command.arg("-l");
            if let Some(cwd) = cwd {
                command.current_dir(cwd);
            }
            exec(&mut command)
        }
        HostCommand::Run { cwd, command } => {
            let mut process = Process::new(&command[0]);
            process.args(&command[1..]);
            if let Some(cwd) = cwd {
                process.current_dir(cwd);
            }
            exec(&mut process)
        }
        HostCommand::Status => {
            println!("Host: local Linux");
            crate::lifecycle::status(None)
        }
        HostCommand::Deploy {
            flake,
            configuration,
            max_jobs,
            cores,
        } => {
            let config = config::Config::load(&config::config_path(None)?)?;
            let flake = deployment_flake(&config, flake.as_deref(), configuration.as_deref())?;
            let mut process = Process::new("sudo");
            process.args(["--", "nixos-rebuild", "switch", "--flake", &flake]);
            build_limits(&mut process, *max_jobs, *cores);
            exec(&mut process)
        }
        HostCommand::Start | HostCommand::Stop => bail!(
            "Host start/stop requires a managed Lima VM; the native Linux Host is this machine"
        ),
        _ => bail!("this Host integration requires a Lima client connection"),
    }
}

fn build_limits(command: &mut Process, max_jobs: Option<u32>, cores: Option<u32>) {
    if let Some(jobs) = max_jobs {
        command.args(["--option", "max-jobs", &jobs.to_string()]);
    }
    if let Some(cores) = cores {
        command.args(["--option", "cores", &cores.to_string()]);
    }
}

fn resolve_flake(flake: &str) -> Result<String> {
    ensure!(
        !flake.contains('#'),
        "use --configuration separately from the flake reference"
    );
    if let Some(path) = flake.strip_prefix("path:") {
        return Ok(format!("path:{}", fs::canonicalize(path)?.display()));
    }
    if Path::new(flake).exists() {
        return Ok(fs::canonicalize(flake)?.to_string_lossy().into_owned());
    }
    Ok(flake.into())
}

fn deployment_flake(
    config: &config::Config,
    flake: Option<&str>,
    configuration: Option<&str>,
) -> Result<String> {
    let flake = flake
        .or(config.flake.as_deref())
        .context("configure a consumer flake or pass --flake")?;
    let flake = resolve_flake(flake)?;
    let configuration = configuration.unwrap_or(&config.configuration);
    ensure!(
        !configuration.is_empty() && !configuration.contains(['#', '\n', '\r', '\0']),
        "invalid configuration name"
    );
    Ok(format!("{flake}#{configuration}"))
}

fn stop(client: &Client) -> Result<i32> {
    if client.running()? {
        let executable = quote(&client.config.host_seter);
        let output = client.remote_output(&format!(
            "if [ -x {executable} ]; then {executable} list; fi"
        ))?;
        ensure_output(&output, "list Workspaces before Host shutdown")?;
        for workspace in String::from_utf8(output.stdout)?.lines() {
            config::validate_name(workspace)?;
            let output = client.seter_output(&["down".into(), workspace.into()])?;
            ensure_output(&output, "stop Workspace before Host shutdown")?;
        }
        client.browser_detach()?;
    }
    let _lock = client.lock()?;
    for connection in client.connections()? {
        client.stop_connection(&connection)?;
    }
    status(Process::new("limactl").args(["stop", &client.config.instance]))
}

fn host_status(client: &Client) -> Result<i32> {
    let state = client.lima_value("Status")?;
    println!("Host {}: {state}", client.config.instance);
    client.browser_status()?;
    client.docker_status()?;
    client.forward_list()?;
    Ok(if state == "Running" { 0 } else { 3 })
}

fn docker_context(client: &Client, name: Option<&str>, select: bool) -> Result<i32> {
    let socket = client.docker_connect()?;
    let name = name
        .map(str::to_owned)
        .unwrap_or_else(|| format!("seter-{}", client.config.instance));
    config::validate_name(&name)?;
    let expected = format!("unix://{}", socket.display());
    let output = Process::new("docker")
        .args(["context", "ls", "--format", "{{.Name}}"])
        .output()
        .context("cannot invoke the Docker client; install docker")?;
    ensure_output(&output, "list Docker contexts")?;
    let exists = String::from_utf8(output.stdout)?
        .lines()
        .any(|value| value == name);
    let output = Process::new("docker")
        .args([
            "context",
            if exists { "update" } else { "create" },
            &name,
            "--docker",
            &format!("host={expected}"),
        ])
        .output()?;
    ensure_output(&output, "configure Docker context")?;
    if select {
        let output = Process::new("docker")
            .args(["context", "use", &name])
            .output()?;
        ensure_output(&output, "select Docker context")?;
    }
    println!("Docker context {name}: {expected}");
    Ok(0)
}

fn herdr(client: &Client) -> Result<i32> {
    client.ensure_running()?;
    let local = Process::new("herdr")
        .arg("--version")
        .output()
        .context("cannot invoke the Herdr client; install herdr")?;
    ensure_output(&local, "inspect Herdr client version")?;
    let script = format!(
        "exec \"${{SHELL:-/bin/sh}}\" -lc {}",
        quote("herdr --version")
    );
    let remote = client.remote_output(&script)?;
    ensure_output(&remote, "inspect Host Herdr version")?;
    ensure!(
        String::from_utf8_lossy(&local.stdout).trim()
            == String::from_utf8_lossy(&remote.stdout).trim(),
        "local and Host Herdr versions must match"
    );
    let endpoint = client.endpoint()?;
    let real_ssh = find_executable("ssh")?;
    let directory = client.state.join("herdr-bin");
    config::private_directory(&directory)?;
    let link = directory.join("ssh");
    let executable = env::current_exe()?;
    match fs::read_link(&link) {
        Ok(target) if target == executable => (),
        Ok(_) => {
            fs::remove_file(&link)?;
            symlink(&executable, &link)?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => symlink(&executable, &link)?,
        Err(error) => return Err(error).context("cannot create Herdr SSH transport"),
    }
    let mut paths = vec![directory];
    paths.extend(env::split_paths(&env::var_os("PATH").unwrap_or_default()));
    let mut command = Process::new("herdr");
    command
        .args([
            "--remote",
            &endpoint.destination,
            "--remote-keybindings",
            "server",
        ])
        .env("PATH", env::join_paths(paths)?)
        .env("SETER_CLIENT_CONFIG", &client.config_path)
        .env("SETER_HERDR_REAL_SSH", real_ssh)
        .env("SETER_HERDR_SSH_BRIDGE", "1");
    if let Some(config) = &client.config.herdr_config {
        command.env("HERDR_CONFIG_PATH", config);
    }
    exec(&mut command)
}

fn find_executable(name: &str) -> Result<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    for directory in env::split_paths(&env::var_os("PATH").unwrap_or_default()) {
        let path = directory.join(name);
        if fs::metadata(&path)
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        {
            return Ok(fs::canonicalize(path)?);
        }
    }
    bail!("executable {name} is unavailable")
}

pub fn herdr_bridge() -> Result<Option<i32>> {
    let invoked = env::args_os().next().map(PathBuf::from);
    if invoked.as_deref().and_then(Path::file_name) != Some(std::ffi::OsStr::new("ssh"))
        || env::var_os("SETER_HERDR_SSH_BRIDGE").as_deref() != Some(std::ffi::OsStr::new("1"))
    {
        return Ok(None);
    }
    let client = Client::load(None)?;
    let endpoint = client.endpoint()?;
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args == ["-V"] {
        return exec(
            Process::new(
                env::var_os("SETER_HERDR_REAL_SSH").context("Herdr SSH executable is unset")?,
            )
            .arg("-V"),
        )
        .map(Some);
    }
    let position = args
        .iter()
        .position(|value| value == &endpoint.destination)
        .context("Herdr SSH destination does not match the configured Host")?;
    let mut command = endpoint.session(false, client.config.forward_agent);
    command.args(&args[..=position]);
    if args.len() > position + 1 {
        let script = format!(
            "export CDP_PORT_FILE=\"$HOME/.local/state/seter/client/DevToolsActivePort\"; {}",
            args[position + 1..].join(" ")
        );
        command.arg(script);
    }
    exec(&mut command).map(Some)
}

pub fn workspace(command: &Command, path: Option<&Path>) -> Result<i32> {
    let client = Client::load(path)?;
    let mut arguments = Vec::new();
    let mut tty = false;
    let mut starts = false;
    match command {
        Command::Init { workspace, repo } => {
            arguments.extend(["init".into(), workspace.clone()]);
            repository_argument(&mut arguments, repo);
            starts = true;
        }
        Command::Import {
            workspace,
            repo,
            bundle,
        } => {
            let file = File::open(bundle).context("cannot read local Git bundle")?;
            ensure!(
                file.metadata()?.is_file(),
                "Git bundle must be a regular file"
            );
            arguments.extend(["import".into(), workspace.clone()]);
            repository_argument(&mut arguments, repo);
            client.ensure_running()?;
            let script = format!("set -eu; temporary=$(mktemp); trap 'rm -f \"$temporary\"' EXIT HUP INT TERM; cat >\"$temporary\"; {} --bundle \"$temporary\"", client.seter_command(&arguments));
            return exec(
                client
                    .remote_command(&script, false, true)?
                    .stdin(Stdio::from(file)),
            );
        }
        Command::Up { workspace } => {
            arguments.extend(["up".into(), workspace.clone()]);
            starts = true;
        }
        Command::Down { workspace } => arguments.extend(["down".into(), workspace.clone()]),
        Command::Run {
            workspace,
            repo,
            command,
        } => {
            arguments.extend(["run".into(), workspace.clone()]);
            repository_argument(&mut arguments, repo);
            arguments.push("--".into());
            arguments.extend(command.iter().cloned());
            starts = true;
        }
        Command::Shell {
            workspace,
            repo,
            root,
        } => {
            arguments.extend(["shell".into(), workspace.clone()]);
            repository_argument(&mut arguments, repo);
            if *root {
                arguments.push("--root".into());
            }
            tty = interactive();
            starts = true;
        }
        Command::Status { workspace } => {
            arguments.push("status".into());
            arguments.extend(workspace.iter().cloned());
        }
        Command::List => arguments.push("list".into()),
        Command::Ip { workspace } => arguments.extend(["ip".into(), workspace.clone()]),
        Command::Audit {
            workspace,
            since,
            paths,
        } => {
            arguments.extend([
                "audit".into(),
                workspace.clone(),
                "--since".into(),
                since.clone(),
            ]);
            if *paths {
                arguments.push("--paths".into());
            }
        }
        Command::Policy { command } => {
            let (action, workspace, file) = match command {
                PolicyCommand::Review { workspace, file } => {
                    tty = interactive();
                    ("review", workspace, file)
                }
                PolicyCommand::Status { workspace, file } => ("status", workspace, file),
            };
            arguments.extend([
                "policy".into(),
                action.into(),
                workspace.clone(),
                "--file".into(),
                client.policy_path(file)?,
            ]);
        }
        Command::SshHostKey { workspace } => {
            arguments.extend(["ssh-host-key".into(), workspace.clone()])
        }
        Command::ProxyCa => arguments.push("proxy-ca".into()),
        Command::Reset {
            workspace,
            home,
            nix_store,
            all_state,
            yes,
        } => {
            arguments.extend(["reset".into(), workspace.clone()]);
            for (selected, flag) in [
                (*home, "--home"),
                (*nix_store, "--nix-store"),
                (*all_state, "--all-state"),
                (*yes, "--yes"),
            ] {
                if selected {
                    arguments.push(flag.into());
                }
            }
            tty = !yes && interactive();
        }
        Command::DestroyProject { workspace, yes } => {
            arguments.extend(["destroy-project".into(), workspace.clone()]);
            if *yes {
                arguments.push("--yes".into());
            }
            tty = !yes && interactive();
        }
        Command::Gc => arguments.push("gc".into()),
        _ => bail!("internal commands cannot use the client transport"),
    }
    if starts {
        client.ensure_running()?;
    } else {
        ensure!(client.running()?, "Host is stopped; use seter host start");
    }
    exec(&mut client.remote_command(
        &format!("exec {}", client.seter_command(&arguments)),
        tty,
        true,
    )?)
}

fn repository_argument(arguments: &mut Vec<String>, repository: &Option<String>) {
    if let Some(repository) = repository {
        arguments.extend(["--repo".into(), repository.clone()]);
    }
}
