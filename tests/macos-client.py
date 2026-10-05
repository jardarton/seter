import http.server
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request


binary = str(Path(sys.argv[1]).resolve())
python = sys.executable


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def executable(path, source):
    path.write_text(f"#!{python}\n" + source)
    path.chmod(0o755)


class Browser(http.server.BaseHTTPRequestHandler):
    identity = "synthetic-browser"

    def do_GET(self):
        body = json.dumps({"webSocketDebuggerUrl":
                           f"ws://127.0.0.1:{self.server.server_port}/devtools/browser/{self.identity}"}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Docker(socketserver.BaseRequestHandler):
    def handle(self):
        request = self.request.recv(4096)
        assert request.startswith(b"GET /_ping HTTP/1.1\r\n"), request
        self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")


with tempfile.TemporaryDirectory(prefix="seter-client-") as temporary:
    root = Path(temporary)
    tools = root / "bin"
    tools.mkdir()
    remote_home = root / "remote-home"
    remote_home.mkdir()
    config = root / "client.toml"
    events = root / "events.jsonl"
    lima_state = root / "lima.json"
    context_state = root / "contexts.json"
    ssh_config = root / "ssh.config"
    browser_file = root / "DevToolsActivePort"
    host_socket = root / "daemon.sock"
    exchange = root / "exchange"
    exchange.mkdir()
    mount = root / "host-exchange"
    mount.mkdir()
    (exchange / "policy.toml").write_text("version = 1\n")
    (mount / "policy.toml").write_text("version = 1\n")
    herdr_config = root / "herdr.toml"
    herdr_config.write_text("")
    lima_state.write_text(json.dumps({"status": "Stopped"}))
    context_state.write_text(json.dumps({"contexts": {}, "selected": None}))
    executable(tools / "limactl", f'''
import json
from pathlib import Path
import sys
state_path = Path({str(lima_state)!r})
state = json.loads(state_path.read_text())
args = sys.argv[1:]
if args[0] == "list":
    assert args[-1] == "example", args
    field = args[args.index("--format") + 1]
    print({{"{{{{.Status}}}}": state["status"], "{{{{.SSHConfigFile}}}}": {str(ssh_config)!r}, "{{{{.Dir}}}}": {str(root)!r}}}[field])
elif args[0] in ["start", "stop"]:
    assert args[-1] == "example", args
    state["status"] = "Running" if args[0] == "start" else "Stopped"
    state_path.write_text(json.dumps(state))
else:
    raise AssertionError(args)
''')
    executable(tools / "docker", f'''
import json
from pathlib import Path
import sys
path = Path({str(context_state)!r})
state = json.loads(path.read_text())
args = sys.argv[1:]
assert args[0] == "context", args
if args[1] == "ls":
    print("\\n".join(state["contexts"]))
elif args[1] in ["create", "update"]:
    state["contexts"][args[2]] = args[args.index("--docker") + 1]
elif args[1] == "use":
    state["selected"] = args[2]
else:
    raise AssertionError(args)
path.write_text(json.dumps(state))
''')
    executable(tools / "nixos-rebuild", f'''
import json, os, sys
from pathlib import Path
Path({str(root / 'deployment.json')!r}).write_text(json.dumps({{"args": sys.argv[1:], "ssh": os.environ["NIX_SSHOPTS"]}}))
''')
    executable(tools / "herdr", '''
import os, subprocess, sys
if sys.argv[1:] == ["--version"]:
    print("herdr synthetic-1")
else:
    args = sys.argv[1:]
    assert args[-2:] == ["--remote-keybindings", "server"], args
    destination = args[args.index("--remote") + 1]
    result = subprocess.run(["ssh", "-T", destination, 'printf "herdr-connected:%s" "$CDP_PORT_FILE"'], check=False)
    sys.exit(result.returncode)
''')
    executable(tools / "host-shell", '''
import os, sys
args = sys.argv[1:]
args = ["-c" if arg == "-lc" else arg for arg in args]
os.execv("/bin/sh", ["sh", *args])
''')
    host_seter = tools / "host-seter"
    executable(host_seter, f'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[0] == "__client-probe":
    os.execv({binary!r}, [{binary!r}, *args])
event = {{"args": args}}
if args[0] == "import":
    bundle = Path(args[args.index("--bundle") + 1])
    event["bundle"] = bundle.read_text()
    event["temporary"] = str(bundle)
with open({str(events)!r}, "a") as stream:
    stream.write(json.dumps(event) + "\\n")
if args[0] == "list":
    print("alpha\\nbeta")
elif args[0] == "run":
    print(json.dumps(args[args.index("--") + 1:]))
    sys.exit(7)
elif args[0] == "status":
    print("running")
else:
    print("completed")
''')
    force = root / "force-command"
    executable(force, f'''
import os
os.environ["HOME"] = {str(remote_home)!r}
os.environ["SHELL"] = {str(tools / 'host-shell')!r}
os.environ["PATH"] = {str(tools)!r} + os.pathsep + os.environ["PATH"]
command = os.environ.get("SSH_ORIGINAL_COMMAND", "exec /bin/sh")
os.execv("/bin/sh", ["sh", "-c", command])
''')
    user = pwd.getpwuid(os.getuid()).pw_name
    for key in ["host", "login"]:
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / key)], check=True)
    port = free_port()
    host_key = (root / "host.pub").read_text().split()
    known_hosts = root / "known_hosts"
    known_hosts.write_text(f"[127.0.0.1]:{port} {host_key[0]} {host_key[1]}\n")
    ssh_config.write_text(f"Host lima-example\n  HostName 127.0.0.1\n  Port {port}\n  User {user}\n  IdentityFile {root}/login\n  IdentitiesOnly yes\n  StrictHostKeyChecking yes\n  UserKnownHostsFile {known_hosts}\n")
    daemon_config = root / "sshd.config"
    daemon_config.write_text(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {root}/host\nPidFile {root}/pid\nAuthorizedKeysFile {root}/login.pub\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nAllowUsers {user}\nForceCommand {force}\n")
    daemon_log = open(root / "sshd.log", "w+")
    daemon = subprocess.Popen([shutil.which("sshd"), "-D", "-e", "-f", str(daemon_config)], stdout=daemon_log, stderr=daemon_log)
    browser = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Browser)
    docker = socketserver.ThreadingUnixStreamServer(str(host_socket), Docker)
    for server in [browser, docker]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    browser_file.write_text(f"{browser.server_port}\n/devtools/browser/{Browser.identity}\n")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SETER_")}
    environment.update(PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       XDG_STATE_HOME=str(root / "state"), TMPDIR=str(root),
                       HOME=str(root / "client-home"))
    environment["HOME"] = str(root / "client-home")
    (root / "client-home").mkdir()

    def run(*args, expected=0, input=None):
        result = subprocess.run([binary, "--client-config", str(config), *args],
                                env=environment, input=input, text=True,
                                capture_output=True, timeout=30)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return result

    try:
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=.1):
                    break
            except OSError:
                assert daemon.poll() is None, "SSH fixture failed to start"
                time.sleep(.02)
        run("host", "configure", "--lima", "example", "--flake", str(exchange),
            "--host-seter", str(host_seter),
            "--exchange-directory", str(exchange), "--exchange-mount", str(mount),
            "--cdp-port-file", str(browser_file), "--docker-socket", str(host_socket),
            "--herdr-config", str(herdr_config), "--forward-agent", "false")
        assert config.stat().st_mode & 0o777 == 0o600
        run("host", "status", expected=3)
        literal = "a'b $(printf wrong)\nsecond line"
        result = run("host", "run", "--", "printf", "%s", literal)
        assert result.stdout == literal
        assert json.loads(lima_state.read_text())["status"] == "Running"
        result = run("host", "run", "--cwd", str(remote_home), "--", "pwd")
        assert result.stdout.strip() == str(remote_home)
        assert run("host", "run", "--", "sh", "-c", "exit 19", expected=19).returncode == 19
        result = run("run", "alpha", "--repo", "backend", "--", "printf", literal, expected=7)
        assert json.loads(result.stdout) == ["printf", literal]
        assert run("list").stdout == "alpha\nbeta\n"
        run("policy", "status", "alpha", "--file", str(exchange / "policy.toml"))
        event = json.loads(events.read_text().splitlines()[-1])
        assert event["args"][-1] == str(mount / "policy.toml")
        bundle = root / "source.bundle"
        bundle.write_text("synthetic committed objects")
        run("import", "alpha", "--bundle", str(bundle))
        event = json.loads(events.read_text().splitlines()[-1])
        assert event["bundle"] == bundle.read_text()
        assert not Path(event["temporary"]).exists()
        run("host", "deploy", "--max-jobs", "2", "--cores", "2")
        deployment = json.loads((root / "deployment.json").read_text())
        assert f"{exchange}#seter-host" in deployment["args"]
        assert deployment["args"].count("lima-example") == 2
        assert shlex.split(deployment["ssh"])[1] == str(ssh_config)
        cdp_port = free_port()
        run("host", "browser", "attach", "--port", str(cdp_port))
        endpoint = remote_home / ".local/state/seter/client/DevToolsActivePort"
        assert endpoint.read_text() == f"{cdp_port}\n/devtools/browser/{Browser.identity}\n"
        assert endpoint.stat().st_mode & 0o777 == 0o600
        run("host", "browser", "status")
        run("host", "browser", "attach", "--port", str(cdp_port))
        run("host", "configure", "--lima", "example", expected=1)
        Browser.identity = "restarted-browser"
        browser_file.write_text(f"{browser.server_port}\n/devtools/browser/{Browser.identity}\n")
        assert "stale" in run("host", "browser", "status", expected=3).stdout
        run("host", "browser", "attach", "--port", str(cdp_port))
        assert "herdr-connected:" in run("host", "herdr").stdout
        result = run("host", "docker", "env")
        assert result.stdout.startswith("export DOCKER_HOST=")
        docker_url = shlex.split(result.stdout)[1].split("=", 1)[1]
        assert Path(docker_url.removeprefix("unix://")).is_socket()
        run("host", "docker", "status")
        run("host", "docker", "context")
        assert json.loads(context_state.read_text())["selected"] is None
        run("host", "docker", "context", "--use")
        contexts = json.loads(context_state.read_text())
        assert contexts["selected"] == "seter-example"
        assert contexts["contexts"]["seter-example"] == "host=" + docker_url
        local_port = free_port()
        run("host", "forward", "start", str(browser.server_port), "--local-port", str(local_port))
        response = urllib.request.urlopen(f"http://127.0.0.1:{local_port}/json/version", timeout=3)
        assert Browser.identity in response.read().decode()
        assert str(local_port) in run("host", "forward", "list").stdout
        run("host", "forward", "start", str(browser.server_port), "--local-port", str(local_port))
        run("host", "forward", "start", str(browser.server_port), "--local-port", str(browser.server_port), expected=1)
        run("host", "forward", "stop", str(local_port))
        run("host", "docker", "disconnect")
        run("host", "docker", "status", expected=3)
        run("host", "browser", "detach")
        assert not endpoint.exists()
        run("host", "browser", "status", expected=3)
        run("host", "docker", "env")
        run("host", "browser", "attach", "--port", str(cdp_port))
        run("host", "forward", "start", str(browser.server_port), "--local-port", str(local_port))
        run("host", "stop")
        assert json.loads(lima_state.read_text())["status"] == "Stopped"
        assert not endpoint.exists()
        assert not list((root / "state").rglob("*.json"))
        shutdown = [json.loads(line)["args"] for line in events.read_text().splitlines()]
        assert ["down", "alpha"] in shutdown and ["down", "beta"] in shutdown
        run("status", expected=1)
        assert json.loads(lima_state.read_text())["status"] == "Stopped"
        run("host", "start")
        run("host", "stop")
    finally:
        for args in [("host", "browser", "detach"), ("host", "docker", "disconnect")]:
            subprocess.run([binary, "--client-config", str(config), *args], env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        for path in (root / "state").rglob("forward-*.json"):
            port = path.stem.removeprefix("forward-")
            subprocess.run([binary, "--client-config", str(config), "host", "forward", "stop", port],
                           env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        daemon.terminate()
        daemon.wait(timeout=10)
        for server in [browser, docker]:
            server.shutdown()
            server.server_close()

print("Native client integration passed with real SSH, TCP, and Unix-socket forwarding")
