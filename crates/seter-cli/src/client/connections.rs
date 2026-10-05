use std::{
    fs, io,
    os::unix::fs::FileTypeExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};

use super::{
    config::{self, atomic_write},
    probe,
    transport::{ensure_output, quote, Client, Endpoint},
};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Connection {
    pub name: String,
    pub endpoint: Endpoint,
    pub forward: String,
    pub reverse: bool,
    pub local_port: Option<u16>,
    pub remote_port: Option<u16>,
    pub source_file: Option<PathBuf>,
    pub websocket_path: Option<String>,
}

impl Client {
    fn connection_path(&self, name: &str) -> PathBuf {
        self.state.join(format!("{name}.json"))
    }

    fn control_path(&self, name: &str) -> PathBuf {
        self.sockets
            .join(format!("c{}", config::identifier(name.as_bytes())))
    }

    pub fn connection(&self, name: &str) -> Result<Option<Connection>> {
        let path = self.connection_path(name);
        match fs::read(&path) {
            Ok(contents) => {
                let connection: Connection =
                    serde_json::from_slice(&contents).context("invalid client connection state")?;
                ensure!(connection.name == name, "client connection name mismatch");
                Ok(Some(connection))
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).context("cannot read client connection state"),
        }
    }

    pub fn connections(&self) -> Result<Vec<Connection>> {
        if !self.state.exists() {
            return Ok(Vec::new());
        }
        let mut result = Vec::new();
        for entry in fs::read_dir(&self.state)? {
            let path = entry?.path();
            if path
                .extension()
                .is_some_and(|extension| extension == "json")
            {
                let name = path
                    .file_stem()
                    .and_then(|name| name.to_str())
                    .context("invalid connection state filename")?;
                if let Some(connection) = self.connection(name)? {
                    result.push(connection);
                }
            }
        }
        result.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(result)
    }

    pub fn connection_alive(&self, connection: &Connection) -> Result<bool> {
        let output = connection
            .endpoint
            .ssh()
            .arg("-S")
            .arg(self.control_path(&connection.name))
            .args(["-O", "check", "-o", "ForwardAgent=no"])
            .arg(&connection.endpoint.destination)
            .stdin(Stdio::null())
            .output()
            .context("cannot check SSH connection")?;
        Ok(output.status.success())
    }

    pub fn start_connection(&self, connection: &Connection) -> Result<()> {
        ensure!(
            self.running()?,
            "Host stopped before the connection was established"
        );
        if let Some(previous) = self.connection(&connection.name)? {
            if previous == *connection && self.connection_alive(&previous)? {
                return Ok(());
            }
            self.stop_connection(&previous)?;
        }
        let control = self.control_path(&connection.name);
        if control.exists() {
            ensure!(
                !self.connection_alive(connection)?,
                "unregistered SSH connection is still active"
            );
            fs::remove_file(&control)?;
        }
        let output = connection
            .endpoint
            .ssh()
            .args([
                "-o",
                "ControlMaster=yes",
                "-o",
                "ControlPersist=no",
                "-o",
                "ForwardAgent=no",
                "-o",
                "BatchMode=yes",
                "-o",
                "ExitOnForwardFailure=yes",
                "-o",
                "StreamLocalBindMask=0177",
                "-o",
                "StreamLocalBindUnlink=no",
            ])
            .arg("-S")
            .arg(&control)
            .arg("-fNT")
            .arg(if connection.reverse { "-R" } else { "-L" })
            .arg(&connection.forward)
            .arg(&connection.endpoint.destination)
            .stdin(Stdio::null())
            .output()
            .context("cannot establish SSH forward")?;
        ensure_output(&output, "establish SSH forward")?;
        if let Err(error) = atomic_write(
            &self.connection_path(&connection.name),
            &serde_json::to_vec_pretty(connection)?,
        ) {
            let _ = self.stop_connection(connection);
            return Err(error);
        }
        Ok(())
    }

    pub fn stop_connection(&self, connection: &Connection) -> Result<()> {
        if self.connection_alive(connection)? {
            let output = connection
                .endpoint
                .ssh()
                .arg("-S")
                .arg(self.control_path(&connection.name))
                .args(["-O", "exit", "-o", "ForwardAgent=no"])
                .arg(&connection.endpoint.destination)
                .stdin(Stdio::null())
                .output()?;
            ensure_output(&output, "close SSH connection")?;
        }
        remove_if_present(&self.connection_path(&connection.name))?;
        remove_if_present(&self.control_path(&connection.name))?;
        if connection.name == "docker" {
            remove_socket(&self.state.join("docker.sock"))?;
        }
        Ok(())
    }

    pub fn browser_attach(
        &self,
        requested_file: Option<&Path>,
        requested_port: Option<u16>,
    ) -> Result<i32> {
        let file = self.browser_source(requested_file)?;
        let (source_port, websocket_path) = read_browser_endpoint(&file)?;
        probe::browser(source_port, Some(&websocket_path))?;
        let port = requested_port.unwrap_or(self.config.cdp_port);
        self.ensure_running()?;
        let _lock = self.lock()?;
        let connection = Connection {
            name: "browser".into(),
            endpoint: self.endpoint()?,
            forward: format!("127.0.0.1:{port}:127.0.0.1:{source_port}"),
            reverse: true,
            local_port: Some(source_port),
            remote_port: Some(port),
            source_file: Some(file),
            websocket_path: Some(websocket_path.clone()),
        };
        self.start_connection(&connection)?;
        let result = (|| -> Result<()> {
            let output = self.seter_output(&[
                "__client-probe".into(),
                "--port".into(),
                port.to_string(),
                "--websocket-path".into(),
                websocket_path.clone(),
            ])?;
            ensure_output(&output, "verify forwarded CDP endpoint")?;
            let script = format!(
                "set -eu; umask 077; directory=\"$HOME/.local/state/seter/client\"; mkdir -p \"$directory\"; temporary=$(mktemp \"$directory/.endpoint.XXXXXX\"); trap 'rm -f \"$temporary\"' EXIT HUP INT TERM; printf '%s\\n%s\\n' {} {} >\"$temporary\"; mv -f \"$temporary\" \"$directory/DevToolsActivePort\"",
                quote(&port.to_string()), quote(&websocket_path),
            );
            ensure_output(&self.remote_output(&script)?, "publish Host CDP endpoint")
        })();
        if let Err(error) = result {
            let _ = self.stop_connection(&connection);
            return Err(error);
        }
        println!("Chrome CDP: ws://127.0.0.1:{port}{websocket_path} (Host loopback)");
        println!("Host CDP_PORT_FILE: $HOME/.local/state/seter/client/DevToolsActivePort");
        Ok(0)
    }

    pub fn browser_detach(&self) -> Result<i32> {
        let _lock = self.lock()?;
        if let Some(connection) = self.connection("browser")? {
            if self.running()? {
                let path = connection.websocket_path.as_deref().unwrap_or("");
                let script = format!("file=\"$HOME/.local/state/seter/client/DevToolsActivePort\"; if [ -f \"$file\" ] && [ \"$(sed -n '2p' \"$file\")\" = {} ]; then rm -f \"$file\"; fi", quote(path));
                ensure_output(&self.remote_output(&script)?, "remove Host CDP endpoint")?;
            }
            self.stop_connection(&connection)?;
        }
        println!("Chrome CDP detached");
        Ok(0)
    }

    pub fn browser_status(&self) -> Result<i32> {
        let _lock = self.lock()?;
        let Some(connection) = self.connection("browser")? else {
            println!("Chrome CDP: detached");
            return Ok(3);
        };
        if !self.connection_alive(&connection)? {
            println!("Chrome CDP: disconnected");
            return Ok(3);
        }
        let file = connection
            .source_file
            .as_deref()
            .context("browser state has no source file")?;
        let (port, path) = match read_browser_endpoint(file) {
            Ok(endpoint) => endpoint,
            Err(error) => {
                println!("Chrome CDP: stale ({error})");
                return Ok(3);
            }
        };
        if Some(port) != connection.local_port || Some(&path) != connection.websocket_path.as_ref()
        {
            println!("Chrome CDP: stale; attach the browser again");
            return Ok(3);
        }
        let host_port = connection
            .remote_port
            .context("browser state has no Host port")?;
        let output = self.seter_output(&[
            "__client-probe".into(),
            "--port".into(),
            host_port.to_string(),
            "--websocket-path".into(),
            path.clone(),
        ])?;
        if !output.status.success() {
            println!("Chrome CDP: unreachable; attach the browser again");
            return Ok(3);
        }
        println!("Chrome CDP: ws://127.0.0.1:{host_port}{path} (Host loopback)");
        Ok(0)
    }

    fn browser_source(&self, requested: Option<&Path>) -> Result<PathBuf> {
        if let Some(path) = requested.or(self.config.cdp_port_file.as_deref()) {
            return fs::canonicalize(path).context("Chrome endpoint file is unavailable");
        }
        let base = config::home()?.join("Library/Application Support/Google");
        [base.join("Chrome/DevToolsActivePort"), base.join("Chrome Beta/DevToolsActivePort")]
            .into_iter().filter(|path| path.is_file())
            .max_by_key(|path| fs::metadata(path).and_then(|metadata| metadata.modified()).ok())
            .context("Chrome DevToolsActivePort file not found; enable remote debugging and configure --cdp-port-file")
    }

    pub fn docker_connect(&self) -> Result<PathBuf> {
        self.ensure_running()?;
        let _lock = self.lock()?;
        let socket = self.state.join("docker.sock");
        ensure!(
            socket.as_os_str().as_encoded_bytes().len() < 104,
            "Docker socket path is too long; set XDG_STATE_HOME to a shorter directory"
        );
        let output = self.seter_output(&[
            "__client-probe".into(),
            "--socket".into(),
            self.config.docker_socket.to_string_lossy().into_owned(),
        ])?;
        ensure_output(
            &output,
            "access Host Docker daemon; enable Docker and authorize the Host SSH user",
        )?;
        let connection = Connection {
            name: "docker".into(),
            endpoint: self.endpoint()?,
            forward: format!(
                "{}:{}",
                socket.display(),
                self.config.docker_socket.display()
            ),
            reverse: false,
            local_port: None,
            remote_port: None,
            source_file: None,
            websocket_path: None,
        };
        if !self.connection("docker")?.as_ref().is_some_and(|previous| {
            previous == &connection && self.connection_alive(previous).unwrap_or(false)
        }) {
            if let Some(previous) = self.connection("docker")? {
                self.stop_connection(&previous)?;
            }
            remove_socket(&socket)?;
        }
        self.start_connection(&connection)?;
        if let Err(error) = probe::docker(&socket) {
            let _ = self.stop_connection(&connection);
            return Err(error);
        }
        Ok(socket)
    }

    pub fn docker_status(&self) -> Result<i32> {
        let _lock = self.lock()?;
        let socket = self.state.join("docker.sock");
        if let Some(connection) = self.connection("docker")? {
            if self.connection_alive(&connection)? && probe::docker(&socket).is_ok() {
                println!("Docker: unix://{}", socket.display());
                return Ok(0);
            }
        }
        println!("Docker: disconnected");
        Ok(3)
    }

    pub fn docker_disconnect(&self) -> Result<i32> {
        let _lock = self.lock()?;
        if let Some(connection) = self.connection("docker")? {
            self.stop_connection(&connection)?;
        }
        println!("Docker disconnected");
        Ok(0)
    }

    pub fn forward_start(&self, port: u16, local: Option<u16>, open: bool) -> Result<i32> {
        let local = local.unwrap_or(port);
        ensure!(local >= 1024, "local service port must be at least 1024");
        self.ensure_running()?;
        let _lock = self.lock()?;
        let connection = Connection {
            name: format!("forward-{local}"),
            endpoint: self.endpoint()?,
            forward: format!("127.0.0.1:{local}:127.0.0.1:{port}"),
            reverse: false,
            local_port: Some(local),
            remote_port: Some(port),
            source_file: None,
            websocket_path: None,
        };
        self.start_connection(&connection)?;
        let url = format!("http://127.0.0.1:{local}");
        println!("{url} -> Host 127.0.0.1:{port}");
        if open {
            let output = Command::new("open")
                .arg(&url)
                .output()
                .context("cannot open the development URL")?;
            ensure_output(&output, "open development URL")?;
        }
        Ok(0)
    }

    pub fn forward_list(&self) -> Result<i32> {
        let _lock = self.lock()?;
        for connection in self.connections()? {
            if connection.name.starts_with("forward-") {
                println!(
                    "{} {}",
                    connection.forward,
                    if self.connection_alive(&connection)? {
                        "connected"
                    } else {
                        "disconnected"
                    }
                );
            }
        }
        Ok(0)
    }

    pub fn forward_stop(&self, port: u16) -> Result<i32> {
        let _lock = self.lock()?;
        if let Some(connection) = self.connection(&format!("forward-{port}"))? {
            self.stop_connection(&connection)?;
        }
        println!("Forward {port} stopped");
        Ok(0)
    }
}

fn read_browser_endpoint(path: &Path) -> Result<(u16, String)> {
    ensure!(
        fs::metadata(path)?.len() <= 8192,
        "Chrome endpoint file is too large"
    );
    let contents = fs::read_to_string(path)?;
    let mut lines = contents.lines();
    let port: u16 = lines
        .next()
        .context("Chrome endpoint file is empty")?
        .parse()
        .context("invalid Chrome endpoint port")?;
    ensure!(port > 0, "Chrome endpoint port cannot be zero");
    let path = lines
        .next()
        .context("Chrome endpoint file has no WebSocket path")?
        .to_owned();
    probe::validate_path(&path)?;
    Ok((port, path))
}

fn remove_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).context("cannot remove client connection state"),
    }
}

fn remove_socket(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            ensure!(
                metadata.file_type().is_socket(),
                "refusing to replace a non-socket at {}",
                path.display()
            );
            fs::remove_file(path)?;
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
        Err(error) => return Err(error).context("cannot inspect client socket"),
    }
    Ok(())
}
