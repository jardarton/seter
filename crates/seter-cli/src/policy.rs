use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::{self, Write},
    net::Ipv4Addr,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::OnceLock,
};

use anyhow::{ensure, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use similar::TextDiff;
use toml_edit::{value, Array, ArrayOfTables, DocumentMut, Item, Table};

use crate::{audit, registry::Registry};

pub const ACTIVE_POLICY_PATH: &str = "/etc/seter/policy.json";
const POLICY_VERSION: u32 = 1;
const PUBLIC_SUFFIX_LIST: &str = include_str!("../data/public_suffix_list.dat");

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
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TcpGrant {
    pub host: String,
    pub port: u16,
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
            workspace.egress.http_hosts.sort();
            workspace.egress.passthrough_hosts.sort();
            workspace.egress.tcp.sort();
        }
    }

    pub fn validate(&self, registry: &Registry) -> Result<()> {
        ensure!(
            self.version == POLICY_VERSION,
            "unsupported Policy File version {}; expected {POLICY_VERSION}",
            self.version
        );
        for (name, workspace) in &self.workspaces {
            registry
                .workspace(name)
                .with_context(|| format!("Policy File refers to unknown workspace {name:?}"))?;
            validate_patterns(name, "http-hosts", &workspace.egress.http_hosts)?;
            validate_patterns(
                name,
                "passthrough-hosts",
                &workspace.egress.passthrough_hosts,
            )?;
            for http in &workspace.egress.http_hosts {
                for passthrough in &workspace.egress.passthrough_hosts {
                    ensure!(
                        !patterns_overlap(http, passthrough),
                        "workspace {name:?} has overlapping HTTP and passthrough Host Patterns {http:?} and {passthrough:?}"
                    );
                }
            }
            let mut tcp = BTreeSet::new();
            for grant in &workspace.egress.tcp {
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
        }
        Ok(())
    }
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

pub fn validate_host_pattern(pattern: &str) -> Result<()> {
    ensure!(
        pattern == pattern.to_ascii_lowercase(),
        "Host Patterns must be lower-case"
    );
    if let Some(suffix) = pattern.strip_prefix("*.") {
        validate_exact_host(suffix)?;
        ensure!(
            !suffix.contains('*'),
            "wildcard syntax is allowed only as the complete leading label"
        );
        ensure!(
            !wildcard_suffix_forbidden(suffix),
            "wildcards at public or shared-hosting suffix {suffix:?} are prohibited"
        );
        return Ok(());
    }
    ensure!(
        !pattern.contains('*'),
        "wildcard syntax is allowed only as the complete leading label"
    );
    validate_exact_host(pattern)
}

fn validate_exact_host(host: &str) -> Result<()> {
    if host.parse::<Ipv4Addr>().is_ok() {
        return Ok(());
    }
    ensure!(
        !host.is_empty() && host.len() <= 253 && !host.ends_with('.'),
        "host must be a non-empty DNS name without a trailing dot"
    );
    ensure!(
        host.contains('.'),
        "host must be an absolute multi-label DNS name"
    );
    for label in host.split('.') {
        ensure!(
            !label.is_empty()
                && label.len() <= 63
                && label
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .as_bytes()
                    .last()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'),
            "host contains an invalid DNS label"
        );
    }
    Ok(())
}

// Public suffixes cannot safely be wildcarded. Shared hosting suffixes are
// included explicitly because tenants under them do not share authority.
fn wildcard_suffix_forbidden(suffix: &str) -> bool {
    static RULES: OnceLock<BTreeSet<&'static str>> = OnceLock::new();
    let rules = RULES.get_or_init(|| {
        PUBLIC_SUFFIX_LIST
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && !line.starts_with("//"))
            .collect()
    });
    let labels: Vec<_> = suffix.split('.').collect();
    if labels.len() < 2 || labels.iter().any(|label| label.starts_with("xn--")) {
        return true;
    }
    if rules.contains(format!("!{suffix}").as_str()) {
        return false;
    }
    rules.contains(suffix)
        || suffix
            .split_once('.')
            .is_some_and(|(_, parent)| rules.contains(format!("*.{parent}").as_str()))
}

pub fn patterns_overlap(left: &str, right: &str) -> bool {
    if left == right {
        return true;
    }
    fn wildcard_matches(pattern: &str, exact: &str) -> bool {
        let Some(suffix) = pattern.strip_prefix("*.") else {
            return false;
        };
        exact.strip_suffix(suffix).is_some_and(|prefix| {
            prefix.ends_with('.') && !prefix[..prefix.len() - 1].contains('.') && prefix.len() > 1
        })
    }
    wildcard_matches(left, right) || wildcard_matches(right, left)
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
    for host in http_candidates {
        if !target.egress.http_hosts.contains(&host)
            && prompt(&format!("Add exact intercepted-HTTP grant {host}? [y/N] "))? == "y"
        {
            validate_exact_host(&host)?;
            target.egress.http_hosts.push(host);
        }
    }
    for host in dns_candidates {
        if target.egress.http_hosts.contains(&host)
            || target.egress.passthrough_hosts.contains(&host)
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
    let original_tcp = document
        .get("workspaces")
        .and_then(Item::as_table)
        .and_then(|workspaces| workspaces.get(workspace))
        .and_then(Item::as_table)
        .and_then(|workspace| workspace.get("egress"))
        .and_then(Item::as_table)
        .and_then(|egress| egress.get("tcp"))
        .and_then(Item::as_array_of_tables)
        .cloned();
    let egress = &mut document["workspaces"][workspace]["egress"];

    if original_egress.http_hosts != policy.http_hosts {
        let http_decor = egress
            .get("http-hosts")
            .and_then(Item::as_array)
            .map(|array| array.decor().clone());
        let mut http = Array::new();
        for host in &policy.http_hosts {
            http.push(host.as_str());
        }
        egress["http-hosts"] = value(http);
        if let Some(decor) = http_decor {
            *egress["http-hosts"]
                .as_array_mut()
                .expect("the inserted HTTP policy is an array")
                .decor_mut() = decor;
        }
    }

    if original_egress.passthrough_hosts != policy.passthrough_hosts {
        let passthrough_decor = egress
            .get("passthrough-hosts")
            .and_then(Item::as_array)
            .map(|array| array.decor().clone());
        let mut passthrough = Array::new();
        for host in &policy.passthrough_hosts {
            passthrough.push(host.as_str());
        }
        egress["passthrough-hosts"] = value(passthrough);
        if let Some(decor) = passthrough_decor {
            *egress["passthrough-hosts"]
                .as_array_mut()
                .expect("the inserted passthrough policy is an array")
                .decor_mut() = decor;
        }
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
    Ok(document.to_string())
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
    fn host_pattern_boundaries_are_single_label() {
        assert!(patterns_overlap("*.example.com", "api.example.com"));
        assert!(!patterns_overlap("*.example.com", "example.com"));
        assert!(!patterns_overlap("*.example.com", "deep.api.example.com"));
    }

    #[test]
    fn preserves_comments_while_editing_grants() {
        let original = r#"version = 1
# consumer context stays here
[workspaces.example.egress]
http-hosts = ["old.example.com"] # reviewed manually

[[workspaces.example.egress.tcp]]
# required by the deployment service
host = "deploy.example.com"
port = 2222
"#;
        let policy = EgressPolicy {
            http_hosts: vec!["new.example.com".to_owned()],
            tcp: vec![TcpGrant {
                host: "deploy.example.com".to_owned(),
                port: 2222,
            }],
            ..EgressPolicy::default()
        };
        let rendered = render_workspace_preserving(original, "example", &policy).unwrap();
        assert!(rendered.contains("# consumer context stays here"));
        assert!(rendered.contains("# reviewed manually"));
        assert!(rendered.contains("# required by the deployment service"));
        assert!(rendered.contains("new.example.com"));
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

    #[test]
    fn rejects_recursive_and_shared_hosting_wildcards() {
        for value in [
            "**.example.com",
            "*.*.example.com",
            "*.com",
            "*.github.io",
            "*.s3.amazonaws.com",
            "*.uk.com",
        ] {
            assert!(validate_host_pattern(value).is_err(), "accepted {value}");
        }
        validate_host_pattern("*.example.com").unwrap();
    }

    #[test]
    fn observation_candidates_must_be_exact_hosts() {
        assert!(validate_exact_host("*.example.com").is_err());
        validate_exact_host("api.example.com").unwrap();
    }
}
