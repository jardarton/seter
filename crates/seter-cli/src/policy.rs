use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{self, Write},
    net::Ipv4Addr,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

use anyhow::{ensure, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use similar::TextDiff;
use toml_edit::{value, Array, ArrayOfTables, DocumentMut, Item, Table};

use crate::{
    audit,
    host_patterns::{patterns_overlap, validate_exact_host, validate_host_pattern},
    registry::Registry,
};

pub const ACTIVE_POLICY_PATH: &str = "/etc/seter/policy.json";
const POLICY_VERSION: u32 = 1;

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PolicyFile {
    pub version: u32,
    #[serde(default)]
    pub workspaces: BTreeMap<String, WorkspacePolicy>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WorkspacePolicy {
    #[serde(default)]
    pub egress: EgressPolicy,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EgressPolicy {
    #[serde(default, rename = "http-hosts")]
    pub http_hosts: Vec<String>,
    #[serde(default, rename = "passthrough-hosts")]
    pub passthrough_hosts: Vec<String>,
    #[serde(default)]
    pub tcp: Vec<TcpGrant>,
    #[serde(default, rename = "private-http")]
    pub private_http: Vec<PrivateHttpGrant>,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TcpGrant {
    pub host: String,
    pub port: u16,
}

/// A reviewed exact HTTPS hostname pinned to a non-public IPv4 address.
#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PrivateHttpGrant {
    pub host: String,
    pub address: String,
}

// Mirrors the Nix and proxy validation of Private HTTPS Upstream addresses.
const PRIVATE_UPSTREAM_NETWORKS: [(Ipv4Addr, u8); 4] = [
    (Ipv4Addr::new(10, 0, 0, 0), 8),
    (Ipv4Addr::new(100, 64, 0, 0), 10),
    (Ipv4Addr::new(172, 16, 0, 0), 12),
    (Ipv4Addr::new(192, 168, 0, 0), 16),
];

fn address_in_network(address: &str, network: Ipv4Addr, prefix: u8) -> bool {
    let Ok(parsed) = address.parse::<Ipv4Addr>() else {
        return false;
    };
    let mask = u32::MAX.checked_shl(32 - u32::from(prefix)).unwrap_or(0);
    u32::from(parsed) & mask == u32::from(network) & mask
}

fn private_upstream_address(address: &str) -> bool {
    address
        .parse::<Ipv4Addr>()
        .is_ok_and(|parsed| parsed.to_string() == address)
        && PRIVATE_UPSTREAM_NETWORKS
            .iter()
            .any(|(network, prefix)| address_in_network(address, *network, *prefix))
}

impl PolicyFile {
    pub fn load(path: &Path, registry: &Registry) -> Result<Self> {
        let text = fs::read_to_string(path)
            .with_context(|| format!("failed to read Policy File {}", path.display()))?;
        let mut policy: Self = toml::from_str(&text)
            .with_context(|| format!("invalid Policy File TOML in {}", path.display()))?;
        policy.normalize();
        policy.validate(registry)?;
        Ok(policy)
    }

    fn normalize(&mut self) {
        for workspace in self.workspaces.values_mut() {
            workspace
                .egress
                .http_hosts
                .iter_mut()
                .for_each(|host| *host = host.to_ascii_lowercase());
            workspace
                .egress
                .passthrough_hosts
                .iter_mut()
                .for_each(|host| *host = host.to_ascii_lowercase());
            workspace
                .egress
                .tcp
                .iter_mut()
                .for_each(|grant| grant.host = grant.host.to_ascii_lowercase());
            workspace
                .egress
                .private_http
                .iter_mut()
                .for_each(|grant| grant.host = grant.host.to_ascii_lowercase());
            workspace.egress.http_hosts.sort();
            workspace.egress.passthrough_hosts.sort();
            workspace.egress.tcp.sort();
            workspace.egress.private_http.sort();
        }
    }

    pub fn validate(&self, registry: &Registry) -> Result<()> {
        ensure!(
            self.version == POLICY_VERSION,
            "unsupported Policy File version {}; expected {POLICY_VERSION}",
            self.version
        );
        for (name, workspace) in &self.workspaces {
            let registered = registry
                .workspace(name)
                .with_context(|| format!("Policy File refers to unknown workspace {name:?}"))?;
            validate_egress(name, &workspace.egress)?;
            let network = &registered.runner.identity.network;
            let repository_hosts = registered
                .repositories
                .values()
                .filter_map(|repository| repository.host())
                .collect::<Vec<_>>();
            for grant in &workspace.egress.private_http {
                ensure!(
                    !repository_hosts.contains(&grant.host),
                    "workspace {name:?} private-http host {:?} is also a repository host",
                    grant.host
                );
                ensure!(
                    !address_in_network(&grant.address, network.address, network.prefix_length),
                    "workspace {name:?} private-http address {:?} is inside the Seter workspace subnet",
                    grant.address
                );
            }
        }
        Ok(())
    }
}

fn validate_egress(name: &str, egress: &EgressPolicy) -> Result<()> {
    validate_patterns(name, "http-hosts", &egress.http_hosts)?;
    validate_patterns(name, "passthrough-hosts", &egress.passthrough_hosts)?;
    for http in &egress.http_hosts {
        for passthrough in &egress.passthrough_hosts {
            ensure!(
                    !patterns_overlap(http, passthrough),
                    "workspace {name:?} has overlapping HTTP and passthrough Host Patterns {http:?} and {passthrough:?}"
                );
        }
    }
    let mut tcp = BTreeSet::new();
    for grant in &egress.tcp {
        validate_exact_host(&grant.host).with_context(|| {
            format!(
                "workspace {name:?} has invalid direct-TCP host {:?}",
                grant.host
            )
        })?;
        ensure!(
            grant.port != 80 && grant.port != 443,
            "workspace {name:?} direct TCP must not use intercepted ports 80 or 443"
        );
        ensure!(
            tcp.insert(grant),
            "workspace {name:?} contains duplicate direct-TCP grant {}:{}",
            grant.host,
            grant.port
        );
    }
    let mut private_hosts = BTreeSet::new();
    for grant in &egress.private_http {
        let host = grant.host.as_str();
        validate_exact_host(host).with_context(|| {
            format!("workspace {name:?} has invalid private-http host {host:?}")
        })?;
        ensure!(
            host.parse::<Ipv4Addr>().is_err(),
            "workspace {name:?} private-http host {host:?} must be a DNS name, not an IPv4 literal"
        );
        ensure!(
                private_upstream_address(&grant.address),
                "workspace {name:?} private-http address {:?} must be a canonical IPv4 address in 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, or 192.168.0.0/16",
                grant.address
            );
        ensure!(
            private_hosts.insert(host),
            "workspace {name:?} contains duplicate private-http host {host:?}"
        );
        ensure!(
                !egress
                    .http_hosts
                    .iter()
                    .chain(&egress.passthrough_hosts)
                    .any(|pattern| patterns_overlap(pattern, host))
                    && !egress.tcp.iter().any(|tcp| tcp.host == host),
                "workspace {name:?} private-http host {host:?} must not also be an HTTP, passthrough, or direct-TCP destination"
            );
    }
    Ok(())
}

fn validate_patterns(workspace: &str, field: &str, patterns: &[String]) -> Result<()> {
    let mut normalized = BTreeSet::new();
    for pattern in patterns {
        validate_host_pattern(pattern).with_context(|| {
            format!("workspace {workspace:?} has invalid {field} Host Pattern {pattern:?}")
        })?;
        ensure!(
            normalized.insert(pattern.to_ascii_lowercase()),
            "workspace {workspace:?} contains duplicate {field} Host Pattern {pattern:?}"
        );
    }
    Ok(())
}

pub fn status(workspace: &str, file: &Path) -> Result<i32> {
    let registry = Registry::load_default()?;
    registry.workspace(workspace)?;
    let desired = PolicyFile::load(file, &registry)?;
    let active_path = std::env::var_os("SETER_ACTIVE_POLICY")
        .map(PathBuf::from)
        .unwrap_or_else(|| ACTIVE_POLICY_PATH.into());
    let mut active: PolicyFile =
        serde_json::from_reader(File::open(&active_path).with_context(|| {
            format!(
                "failed to open active policy projection {}",
                active_path.display()
            )
        })?)
        .context("invalid active policy projection")?;
    active.normalize();
    active
        .validate(&registry)
        .context("active host policy is invalid")?;

    let desired = desired
        .workspaces
        .get(workspace)
        .cloned()
        .unwrap_or_default()
        .egress;
    let active = active
        .workspaces
        .get(workspace)
        .cloned()
        .unwrap_or_default()
        .egress;
    let additions = grants(&desired)
        .difference(&grants(&active))
        .cloned()
        .collect::<Vec<_>>();
    let revocations = grants(&active)
        .difference(&grants(&desired))
        .cloned()
        .collect::<Vec<_>>();
    if additions.is_empty() && revocations.is_empty() {
        println!("{workspace}: desired Policy File and active host policy agree");
        return Ok(0);
    }
    println!("{workspace}: policy deployment is pending");
    for grant in additions {
        println!("+ {grant}");
    }
    for grant in revocations {
        println!("- {grant}");
    }
    Ok(2)
}

fn grants(policy: &EgressPolicy) -> BTreeSet<String> {
    policy
        .http_hosts
        .iter()
        .map(|host| format!("http {host}"))
        .chain(
            policy
                .passthrough_hosts
                .iter()
                .map(|host| format!("passthrough {host}")),
        )
        .chain(
            policy
                .tcp
                .iter()
                .map(|grant| format!("tcp {}:{}", grant.host, grant.port)),
        )
        .chain(
            policy
                .private_http
                .iter()
                .map(|grant| format!("private-http {}={}", grant.host, grant.address)),
        )
        .collect()
}

pub fn review(workspace: &str, file: &Path) -> Result<i32> {
    let registry = Registry::load_default()?;
    registry.workspace(workspace)?;
    let lock_path = PathBuf::from(format!("{}.lock", file.display()));
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .open(&lock_path)
        .with_context(|| format!("failed to open Policy File lock {}", lock_path.display()))?;
    lock.try_lock_exclusive()
        .with_context(|| format!("Policy File {} is already being reviewed", file.display()))?;

    let original_text = fs::read_to_string(file)
        .with_context(|| format!("failed to read Policy File {}", file.display()))?;
    let mut policy = PolicyFile::load(file, &registry)?;
    let initial_policy = policy.clone();
    let observations = audit::collect(workspace, None)?;
    if observations.truncated {
        eprintln!(
            "warning: review is limited to the newest grouped Policy Observations; use seter audit --since to inspect a narrower interval"
        );
    }
    let observations = observations.groups;
    let target = policy.workspaces.entry(workspace.to_owned()).or_default();
    let existing = grants(&target.egress).into_iter().collect::<Vec<_>>();

    println!(
        "Reviewing {} grouped Policy Observations for {workspace}.",
        observations.len()
    );
    let mut http_candidates = BTreeSet::new();
    let mut dns_candidates = BTreeSet::new();
    let mut tcp_candidates = BTreeSet::new();
    for observation in observations.values() {
        if observation.decision != "deny" {
            continue;
        }
        if observation.method.is_some() {
            if let Some(host) = &observation.destination {
                http_candidates.insert(host.clone());
            }
        } else if observation.boundary == "dns" || observation.boundary == "tls" {
            if let Some(host) = &observation.destination {
                dns_candidates.insert(host.clone());
            }
        } else if observation.boundary == "direct-tcp" {
            if let (Some(host), Some(port)) = (&observation.destination, observation.port) {
                tcp_candidates.insert((host.clone(), port));
            }
        }
    }
    // A private-http host is already granted for HTTPS; its denied cleartext
    // or DNS observations cannot justify a conflicting grant.
    let private_hosts = target
        .egress
        .private_http
        .iter()
        .map(|grant| grant.host.clone())
        .collect::<BTreeSet<_>>();
    for host in http_candidates {
        if !target.egress.http_hosts.contains(&host)
            && !private_hosts.contains(&host)
            && prompt(&format!("Add exact intercepted-HTTP grant {host}? [y/N] "))? == "y"
        {
            validate_exact_host(&host)?;
            target.egress.http_hosts.push(host);
        }
    }
    for host in dns_candidates {
        if target.egress.http_hosts.contains(&host)
            || target.egress.passthrough_hosts.contains(&host)
            || private_hosts.contains(&host)
        {
            continue;
        }
        println!("DNS-only evidence for {host} is ambiguous and does not identify a protocol.");
        match prompt("Classify as [h]ttp, [p]assthrough, [t]cp, or [s]kip: ")?.as_str() {
            "h" => {
                validate_exact_host(&host)?;
                target.egress.http_hosts.push(host);
            }
            "p" => {
                validate_exact_host(&host)?;
                target.egress.passthrough_hosts.push(host);
            }
            "t" => {
                validate_exact_host(&host)?;
                let port: u16 = prompt("Exact TCP port: ")?
                    .parse()
                    .context("invalid TCP port")?;
                target.egress.tcp.push(TcpGrant { host, port });
            }
            _ => {}
        }
    }
    for (host, port) in tcp_candidates {
        let grant = TcpGrant { host, port };
        if !target.egress.tcp.contains(&grant)
            && prompt(&format!(
                "Add exact direct-TCP grant {}:{}? [y/N] ",
                grant.host, grant.port
            ))? == "y"
        {
            validate_exact_host(&grant.host)?;
            target.egress.tcp.push(grant);
        }
    }

    for grant in existing {
        if prompt(&format!("Revoke existing grant {grant}? [y/N] "))? == "y" {
            remove_grant(&mut target.egress, &grant);
        }
    }
    policy.normalize();
    policy.validate(&registry)?;
    if policy == initial_policy {
        println!("No Policy File changes selected.");
        return Ok(0);
    }
    let target_policy = policy
        .workspaces
        .get(workspace)
        .cloned()
        .unwrap_or_default()
        .egress;
    let rendered = render_workspace_preserving(&original_text, workspace, &target_policy)?;
    let mut rendered_policy: PolicyFile =
        toml::from_str(&rendered).context("edited Policy File is invalid")?;
    rendered_policy.normalize();
    rendered_policy.validate(&registry)?;
    if rendered == original_text {
        println!("No Policy File changes selected.");
        return Ok(0);
    }
    print_diff(&original_text, &rendered);
    if prompt("Write this exact diff? [y/N] ")? != "y" {
        println!("Policy File unchanged.");
        return Ok(0);
    }
    atomic_write(file, rendered.as_bytes())?;
    println!(
        "Updated {}. Deploy through the trusted host configuration to activate it.",
        file.display()
    );
    Ok(0)
}

fn remove_grant(policy: &mut EgressPolicy, text: &str) {
    if let Some(host) = text.strip_prefix("http ") {
        policy.http_hosts.retain(|item| item != host);
    } else if let Some(host) = text.strip_prefix("passthrough ") {
        policy.passthrough_hosts.retain(|item| item != host);
    } else if let Some(destination) = text.strip_prefix("tcp ") {
        policy
            .tcp
            .retain(|item| format!("{}:{}", item.host, item.port) != destination);
    } else if let Some(destination) = text.strip_prefix("private-http ") {
        policy
            .private_http
            .retain(|item| format!("{}={}", item.host, item.address) != destination);
    }
}

fn prompt(text: &str) -> Result<String> {
    print!("{text}");
    io::stdout().flush()?;
    let mut value = String::new();
    io::stdin()
        .read_line(&mut value)
        .context("failed to read review response")?;
    Ok(value.trim().to_ascii_lowercase())
}

fn print_diff(before: &str, after: &str) {
    print!(
        "{}",
        TextDiff::from_lines(before, after)
            .unified_diff()
            .header("Policy File (current)", "Policy File (proposed)")
    );
}

fn render_workspace_preserving(
    original: &str,
    workspace: &str,
    policy: &EgressPolicy,
) -> Result<String> {
    let mut original_policy: PolicyFile =
        toml::from_str(original).context("failed to parse the original Policy File")?;
    original_policy.normalize();
    let original_egress = original_policy
        .workspaces
        .get(workspace)
        .cloned()
        .unwrap_or_default()
        .egress;
    let mut document = original
        .parse::<DocumentMut>()
        .context("failed to preserve Policy File TOML")?;
    let original_tables = |key: &str| {
        document
            .get("workspaces")
            .and_then(Item::as_table)
            .and_then(|workspaces| workspaces.get(workspace))
            .and_then(Item::as_table)
            .and_then(|workspace| workspace.get("egress"))
            .and_then(Item::as_table)
            .and_then(|egress| egress.get(key))
            .and_then(Item::as_array_of_tables)
            .cloned()
    };
    let original_tcp = original_tables("tcp");
    let original_private_http = original_tables("private-http");
    let egress = &mut document["workspaces"][workspace]["egress"];

    if original_egress.http_hosts != policy.http_hosts {
        replace_string_array_preserving_decor(egress, "http-hosts", &policy.http_hosts);
    }

    if original_egress.passthrough_hosts != policy.passthrough_hosts {
        replace_string_array_preserving_decor(
            egress,
            "passthrough-hosts",
            &policy.passthrough_hosts,
        );
    }

    if original_egress.tcp != policy.tcp {
        let mut tcp = ArrayOfTables::new();
        for grant in &policy.tcp {
            let preserved = original_tcp.as_ref().and_then(|tables| {
                tables.iter().find(|table| {
                    table.get("host").and_then(Item::as_str) == Some(grant.host.as_str())
                        && table.get("port").and_then(Item::as_integer)
                            == Some(i64::from(grant.port))
                })
            });
            if let Some(table) = preserved {
                tcp.push(table.clone());
            } else {
                let mut table = Table::new();
                table.insert("host", value(grant.host.as_str()));
                table.insert("port", value(i64::from(grant.port)));
                tcp.push(table);
            }
        }
        egress["tcp"] = Item::ArrayOfTables(tcp);
    }

    if original_egress.private_http != policy.private_http {
        let mut private_http = ArrayOfTables::new();
        for grant in &policy.private_http {
            let preserved = original_private_http.as_ref().and_then(|tables| {
                tables.iter().find(|table| {
                    table
                        .get("host")
                        .and_then(Item::as_str)
                        .map(str::to_ascii_lowercase)
                        .as_deref()
                        == Some(grant.host.as_str())
                        && table.get("address").and_then(Item::as_str)
                            == Some(grant.address.as_str())
                })
            });
            if let Some(table) = preserved {
                private_http.push(table.clone());
            } else {
                let mut table = Table::new();
                table.insert("host", value(grant.host.as_str()));
                table.insert("address", value(grant.address.as_str()));
                private_http.push(table);
            }
        }
        if private_http.is_empty() {
            if let Some(egress) = egress.as_table_mut() {
                egress.remove("private-http");
            }
        } else {
            egress["private-http"] = Item::ArrayOfTables(private_http);
        }
    }
    Ok(document.to_string())
}

fn replace_string_array_preserving_decor(egress: &mut Item, key: &str, values: &[String]) {
    let decor = egress
        .get(key)
        .and_then(Item::as_array)
        .map(|array| array.decor().clone());
    let mut replacement = Array::new();
    replacement.extend(values.iter().map(String::as_str));
    egress[key] = value(replacement);
    if let Some(decor) = decor {
        *egress[key]
            .as_array_mut()
            .expect("the inserted policy is an array")
            .decor_mut() = decor;
    }
}

fn atomic_write(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .context("Policy File path has no file name")?
        .to_string_lossy();
    let temporary = parent.join(format!(".{name}.seter-{}.tmp", std::process::id()));
    let mode = fs::metadata(path)?.permissions().mode();
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&temporary)
        .with_context(|| {
            format!(
                "failed to create temporary Policy File {}",
                temporary.display()
            )
        })?;
    let result = (|| -> Result<()> {
        output.write_all(contents)?;
        output.sync_all()?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))?;
        fs::rename(&temporary, path).context("failed to atomically replace Policy File")?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::*;

    #[test]
    fn preserves_comments_while_editing_grants() {
        let original = r#"version = 1
# consumer context stays here
[workspaces.example.egress]
http-hosts = ["old.example.com"] # reviewed manually
passthrough-hosts = ["old-tls.example.com"] # TLS exception context

[[workspaces.example.egress.tcp]]
# required by the deployment service
host = "deploy.example.com"
port = 2222
"#;
        let policy = EgressPolicy {
            http_hosts: vec!["new.example.com".to_owned()],
            passthrough_hosts: vec!["new-tls.example.com".to_owned()],
            tcp: vec![TcpGrant {
                host: "deploy.example.com".to_owned(),
                port: 2222,
            }],
            ..EgressPolicy::default()
        };
        let rendered = render_workspace_preserving(original, "example", &policy).unwrap();
        assert!(rendered.contains("# consumer context stays here"));
        assert!(rendered.contains("# reviewed manually"));
        assert!(rendered.contains("# TLS exception context"));
        assert!(rendered.contains("# required by the deployment service"));
        assert!(rendered.contains("new.example.com"));
        assert!(rendered.contains("new-tls.example.com"));
    }

    #[test]
    fn edits_policy_without_optional_tcp_tables() {
        let original = r#"version = 1
[workspaces.example.egress]
http-hosts = ["old.example.com"]
"#;
        let policy = EgressPolicy {
            http_hosts: vec!["new.example.com".to_owned()],
            ..EgressPolicy::default()
        };
        let rendered = render_workspace_preserving(original, "example", &policy).unwrap();
        assert!(rendered.contains("new.example.com"));
    }

    fn private_grant(host: &str, address: &str) -> PrivateHttpGrant {
        PrivateHttpGrant {
            host: host.to_owned(),
            address: address.to_owned(),
        }
    }

    #[test]
    fn accepts_reviewed_private_https_upstreams() {
        let policy: PolicyFile = toml::from_str(
            r#"version = 1
[workspaces.example.egress]
http-hosts = ["api.example.com"]

[[workspaces.example.egress.private-http]]
host = "Service.LAN.example"
address = "192.168.20.5"
"#,
        )
        .unwrap();
        let mut policy = policy;
        policy.normalize();
        let egress = &policy.workspaces["example"].egress;
        assert_eq!(
            egress.private_http,
            vec![private_grant("service.lan.example", "192.168.20.5")]
        );
        validate_egress("example", egress).unwrap();
        assert!(grants(egress).contains("private-http service.lan.example=192.168.20.5"));
        for address in ["10.0.0.2", "100.64.0.1", "172.31.255.254"] {
            validate_egress(
                "example",
                &EgressPolicy {
                    private_http: vec![private_grant("service.lan.example", address)],
                    ..EgressPolicy::default()
                },
            )
            .unwrap();
        }
    }

    #[test]
    fn rejects_unsafe_private_https_upstreams() {
        let rejected = |egress: EgressPolicy| validate_egress("example", &egress).is_err();
        let only = |host: &str, address: &str| EgressPolicy {
            private_http: vec![private_grant(host, address)],
            ..EgressPolicy::default()
        };
        for address in [
            "8.8.8.8",
            "127.0.0.1",
            "169.254.1.1",
            "224.0.0.1",
            "0.0.0.0",
            "192.168.001.1",
            "192.168.1",
            "172.32.0.1",
            "not-an-address",
        ] {
            assert!(rejected(only("service.lan.example", address)), "{address}");
        }
        for host in ["*.lan.example", "10.0.0.2", "single"] {
            assert!(rejected(only(host, "10.0.0.2")), "{host}");
        }
        assert!(rejected(EgressPolicy {
            private_http: vec![
                private_grant("service.lan.example", "10.0.0.2"),
                private_grant("service.lan.example", "10.0.0.3"),
            ],
            ..EgressPolicy::default()
        }));
        assert!(rejected(EgressPolicy {
            http_hosts: vec!["*.lan.example".to_owned()],
            ..only("service.lan.example", "10.0.0.2")
        }));
        assert!(rejected(EgressPolicy {
            passthrough_hosts: vec!["service.lan.example".to_owned()],
            ..only("service.lan.example", "10.0.0.2")
        }));
        assert!(rejected(EgressPolicy {
            tcp: vec![TcpGrant {
                host: "service.lan.example".to_owned(),
                port: 2222,
            }],
            ..only("service.lan.example", "10.0.0.2")
        }));
    }

    #[test]
    fn matches_workspace_subnets() {
        let subnet = Ipv4Addr::new(10, 100, 0, 1);
        assert!(address_in_network("10.100.0.20", subnet, 24));
        assert!(!address_in_network("10.100.1.20", subnet, 24));
        assert!(address_in_network("10.0.0.2", subnet, 8));
        assert!(address_in_network("192.168.20.5", subnet, 0));
        assert!(!address_in_network("not-an-address", subnet, 24));
    }

    #[test]
    fn preserves_and_revokes_private_https_upstreams() {
        let original = r#"version = 1
[workspaces.example.egress]
http-hosts = ["old.example.com"]

[[workspaces.example.egress.private-http]]
# reviewed LAN service
host = "service.lan.example"
address = "10.0.0.2"
"#;
        let mut policy: PolicyFile = toml::from_str(original).unwrap();
        policy.normalize();
        let mut egress = policy.workspaces["example"].egress.clone();
        egress.http_hosts = vec!["new.example.com".to_owned()];
        let rendered = render_workspace_preserving(original, "example", &egress).unwrap();
        assert!(rendered.contains("# reviewed LAN service"));
        assert!(rendered.contains("new.example.com"));

        remove_grant(&mut egress, "private-http service.lan.example=10.0.0.2");
        assert!(egress.private_http.is_empty());
        let rendered = render_workspace_preserving(original, "example", &egress).unwrap();
        assert!(!rendered.contains("service.lan.example"));
        let reparsed: PolicyFile = toml::from_str(&rendered).unwrap();
        assert!(reparsed.workspaces["example"]
            .egress
            .private_http
            .is_empty());
    }

    #[test]
    fn interrupted_atomic_edit_preserves_the_original() {
        let directory = std::env::temp_dir().join(format!(
            "seter-policy-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("policy.toml");
        fs::write(&path, "original\n").unwrap();
        let blocked_temporary =
            directory.join(format!(".policy.toml.seter-{}.tmp", std::process::id()));
        fs::write(&blocked_temporary, "interrupted\n").unwrap();

        assert!(atomic_write(&path, b"replacement\n").is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "original\n");

        fs::remove_file(blocked_temporary).unwrap();
        atomic_write(&path, b"replacement\n").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "replacement\n");
        fs::remove_dir_all(directory).unwrap();
    }
}
