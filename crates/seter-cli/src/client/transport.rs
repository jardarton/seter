use std::{
    env,
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io,
    os::unix::{fs::OpenOptionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
};

use anyhow::{ensure, Context, Result};
use fs2::FileExt;

use super::config::{self, Config};

pub struct Client {
    pub config: Config,
    pub config_path: PathBuf,
    pub state: PathBuf,
    pub sockets: PathBuf,
}

impl Client {
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let path = config::config_path(path)?;
        let config = Config::load(&path)?;
        let identity = config::identifier(path.as_os_str().as_encoded_bytes());
        let state = env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or(config::home()?.join(".local/state"))
            .join("seter/client")
            .join(&identity);
        let sockets = env::temp_dir().join(format!("st-{}-{identity}", unsafe { libc::geteuid() }));
        ensure!(
            sockets.as_os_str().as_encoded_bytes().len() + 20 < 104,
            "temporary directory is too long for SSH control sockets; set TMPDIR to a shorter path"
        );
        Ok(Self {
            config,
            config_path: path,
            state,
            sockets,
        })
    }

    pub fn lock(&self) -> Result<File> {
        config::private_directory(&self.state)?;
        config::private_directory(&self.sockets)?;
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(self.state.join("lock"))?;
        file.lock_exclusive()?;
        Ok(file)
    }

    pub fn lima_value(&self, field: &str) -> Result<String> {
        let output = Command::new("limactl")
            .args([
                "list",
                "--format",
                &format!("{{{{.{field}}}}}"),
                &self.config.instance,
            ])
            .output()
            .context("cannot invoke limactl; install Lima")?;
        ensure_output(&output, "inspect Lima instance")?;
        let value = String::from_utf8(output.stdout)?.trim().to_owned();
        ensure!(
            !value.is_empty() && !value.contains('\n'),
            "Lima instance {:?} is missing or returned an invalid {field}",
            self.config.instance
        );
        Ok(value)
    }

    pub fn running(&self) -> Result<bool> {
        Ok(self.lima_value("Status")? == "Running")
    }

    pub fn start(&self) -> Result<i32> {
        if self.running()? {
            println!("Host {} is running", self.config.instance);
            return Ok(0);
        }
        status(Command::new("limactl").args(["start", "--tty=false", &self.config.instance]))
    }

    pub fn ensure_running(&self) -> Result<()> {
        if !self.running()? {
            let result = Command::new("limactl")
                .args(["start", "--tty=false", &self.config.instance])
                .stdout(io::stderr())
                .status()
                .context("cannot start Lima Host")?;
            ensure!(result.success(), "Lima Host startup failed");
            ensure!(self.running()?, "Lima Host did not reach Running state");
        }
        Ok(())
    }

    pub fn endpoint(&self) -> Result<Endpoint> {
        let ssh_config = PathBuf::from(self.lima_value("SSHConfigFile")?);
        ensure!(
            ssh_config.is_file(),
            "Lima SSH configuration is missing: {}",
            ssh_config.display()
        );
        Ok(Endpoint {
            ssh_config,
            destination: format!("lima-{}", self.config.instance),
        })
    }

    pub fn remote_command(&self, script: &str, tty: bool, agent: bool) -> Result<Command> {
        let endpoint = self.endpoint()?;
        let mut command = endpoint.session(tty, agent && self.config.forward_agent);
        command.arg(&endpoint.destination).arg(script);
        Ok(command)
    }

    pub fn remote_output(&self, script: &str) -> Result<Output> {
        self.remote_command(script, false, false)?
            .stdin(Stdio::null())
            .output()
            .context("cannot execute Host command")
    }

    pub fn seter_command(&self, args: &[String]) -> String {
        let mut command = quote(&self.config.host_seter);
        for argument in args {
            command.push(' ');
            command.push_str(&quote(argument));
        }
        command
    }

    pub fn seter_output(&self, args: &[String]) -> Result<Output> {
        self.remote_output(&self.seter_command(args))
    }

    pub fn host_script(&self, arguments: Option<&[String]>, cwd: Option<&Path>) -> Result<String> {
        let mut script = String::from(
            "export CDP_PORT_FILE=\"$HOME/.local/state/seter/client/DevToolsActivePort\"; ",
        );
        if let Some(cwd) = cwd {
            let cwd = cwd
                .to_str()
                .context("Host working directory must be UTF-8")?;
            script.push_str(&format!("cd {} || exit 72; ", quote(cwd)));
        }
        script.push_str("exec ");
        match arguments {
            Some(arguments) => script.push_str(&join(arguments)),
            None => script.push_str("\"${SHELL:-/bin/sh}\" -l"),
        }
        Ok(script)
    }

    pub fn policy_path(&self, file: &Path) -> Result<String> {
        let path = if file.exists() {
            let root = self.config.exchange_directory.as_ref().context(
                "a local Policy File requires exchange_directory in client configuration",
            )?;
            let root = fs::canonicalize(root)?;
            let file = fs::canonicalize(file)?;
            let relative = file
                .strip_prefix(root)
                .context("local Policy File is outside the configured exchange directory")?;
            self.config.exchange_mount.join(relative)
        } else {
            ensure!(file.is_absolute(), "Host Policy File path must be absolute");
            file.to_path_buf()
        };
        Ok(path
            .to_str()
            .context("Policy File path must be UTF-8")?
            .into())
    }
}

#[derive(Clone, Debug, serde::Deserialize, serde::Serialize, PartialEq, Eq)]
pub struct Endpoint {
    pub ssh_config: PathBuf,
    pub destination: String,
}

impl Endpoint {
    pub fn ssh(&self) -> Command {
        let mut command =
            Command::new(env::var_os("SETER_HERDR_REAL_SSH").unwrap_or_else(|| "ssh".into()));
        command.arg("-F").arg(&self.ssh_config).args([
            "-o",
            "ForwardX11=no",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "ConnectTimeout=10",
        ]);
        command
    }

    pub fn session(&self, tty: bool, agent: bool) -> Command {
        let mut command = self.ssh();
        command.args([
            "-o",
            "ControlMaster=no",
            "-o",
            "ControlPath=none",
            "-o",
            if agent {
                "ForwardAgent=yes"
            } else {
                "ForwardAgent=no"
            },
        ]);
        command.arg(if tty { "-t" } else { "-T" });
        command
    }
}

pub fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn join(arguments: &[String]) -> String {
    arguments
        .iter()
        .map(|arg| quote(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn ensure_output(output: &Output, operation: &str) -> Result<()> {
    ensure!(
        output.status.success(),
        "{operation} failed (exit {}): {}",
        output.status.code().unwrap_or(255),
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(())
}

pub fn status(command: &mut Command) -> Result<i32> {
    let status = command
        .status()
        .with_context(|| format!("cannot execute {:?}", command.get_program()))?;
    Ok(status.code().unwrap_or(255))
}

pub fn exec(command: &mut Command) -> Result<i32> {
    let error = command.exec();
    Err(error).with_context(|| format!("cannot execute {:?}", command.get_program()))
}

pub fn shell() -> impl AsRef<OsStr> {
    env::var_os("SHELL").unwrap_or_else(|| "/bin/sh".into())
}

pub fn interactive() -> bool {
    use io::IsTerminal;
    io::stdin().is_terminal()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_remain_literal_when_transmitted_through_a_shell() {
        let arguments: Vec<String> = ["printf", "%s", "a'b $(exit 9)\nnext"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        let output = Command::new("sh")
            .args(["-c", &join(&arguments)])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stdout).unwrap(), arguments[2]);
    }
}
