use std::{
    collections::BTreeMap,
    env,
    ffi::OsString,
    io::{BufRead, BufReader},
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::registry::Registry;

const MAX_JOURNAL_RECORDS: usize = 20_000;
const MAX_GROUPS: usize = 2_000;
const MAX_SOURCE_RECORDS: usize = MAX_JOURNAL_RECORDS / 2;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuditRecord {
    pub timestamp_micros: u64,
    pub boundary: String,
    pub decision: String,
    pub destination: Option<String>,
    pub port: Option<u16>,
    pub protocol: Option<String>,
    pub method: Option<String>,
    pub reason: String,
    pub path: Option<String>,
}

#[derive(Clone, Debug)]
pub struct AuditGroup {
    pub boundary: String,
    pub decision: String,
    pub destination: Option<String>,
    pub port: Option<u16>,
    pub protocol: Option<String>,
    pub method: Option<String>,
    pub reason: String,
    pub path: Option<String>,
    pub count: u64,
    pub last_timestamp_micros: u64,
}

#[derive(Debug)]
pub struct AuditCollection {
    pub groups: BTreeMap<String, AuditGroup>,
    pub truncated: bool,
}

pub fn show(workspace: &str, since: &str, show_paths: bool) -> Result<i32> {
    let registry = Registry::load_default()?;
    registry.workspace(workspace)?;
    let age = parse_duration(since)?;
    let cutoff = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .saturating_sub(age)
        .as_micros() as u64;
    let observations = collect(workspace, Some(cutoff))?;
    let mut shown = 0;
    for group in observations.groups.values() {
        shown += 1;
        let destination = group.destination.as_deref().unwrap_or("<unknown>");
        let port = group
            .port
            .map(|port| format!(":{port}"))
            .unwrap_or_default();
        let detail = group
            .method
            .as_deref()
            .or(group.protocol.as_deref())
            .unwrap_or("");
        println!(
            "{:>6} {:5} {:16} {}{} {}",
            group.count, group.decision, group.boundary, destination, port, detail
        );
        println!("       {}", group.reason);
        if show_paths {
            if let Some(path) = &group.path {
                println!("       path: {path}");
            }
        }
    }
    if shown == 0 {
        println!("No Policy Observations for {workspace} in the requested interval.");
    }
    if observations.truncated {
        eprintln!(
            "warning: only the newest {MAX_GROUPS} distinct observation groups are shown; narrow --since to inspect a smaller interval"
        );
    }
    Ok(0)
}

pub fn collect(workspace: &str, cutoff: Option<u64>) -> Result<AuditCollection> {
    let registry = Registry::load_default()?;
    registry.workspace(workspace)?;
    let executable = env::var_os("SETER_PRIVILEGED_HELPER")
        .map(PathBuf::from)
        .unwrap_or(env::current_exe().context("failed to locate the seter executable")?);
    let sudo = env::var_os("SETER_SUDO").unwrap_or_else(|| OsString::from("sudo"));
    let mut child = Command::new(sudo)
        .arg("--")
        .arg(executable)
        .arg("__audit")
        .arg(workspace)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .context("failed to execute the workspace-scoped audit helper")?;
    let stdout = child
        .stdout
        .take()
        .context("failed to capture audit helper output")?;
    let mut observations = AuditCollection {
        groups: BTreeMap::new(),
        truncated: false,
    };
    for (index, line) in BufReader::new(stdout).lines().enumerate() {
        ensure!(
            index < MAX_JOURNAL_RECORDS,
            "audit helper exceeded the observation limit"
        );
        let line = line.context("failed to read audit helper output")?;
        ensure!(
            line.len() <= 64 * 1024,
            "audit helper emitted an oversized record"
        );
        let record: AuditRecord =
            serde_json::from_str(&line).context("audit helper emitted an invalid record")?;
        add_record(&mut observations, record, cutoff)?;
    }
    ensure!(
        child.wait()?.success(),
        "workspace-scoped audit helper failed"
    );
    Ok(observations)
}

fn add_record(
    observations: &mut AuditCollection,
    record: AuditRecord,
    cutoff: Option<u64>,
) -> Result<()> {
    if cutoff.is_some_and(|cutoff| record.timestamp_micros < cutoff) {
        return Ok(());
    }
    let key = serde_json::to_string(&(
        &record.boundary,
        &record.decision,
        &record.destination,
        record.port,
        &record.protocol,
        &record.method,
        &record.reason,
    ))?;
    if let Some(group) = observations.groups.get_mut(&key) {
        group.count += 1;
        if record.timestamp_micros >= group.last_timestamp_micros && record.path.is_some() {
            group.path = record.path;
        }
        group.last_timestamp_micros = group.last_timestamp_micros.max(record.timestamp_micros);
    } else if observations.groups.len() >= MAX_GROUPS {
        observations.truncated = true;
    } else {
        observations.groups.insert(
            key,
            AuditGroup {
                boundary: record.boundary,
                decision: record.decision,
                destination: record.destination,
                port: record.port,
                protocol: record.protocol,
                method: record.method,
                reason: record.reason,
                path: record.path,
                count: 1,
                last_timestamp_micros: record.timestamp_micros,
            },
        );
    }
    Ok(())
}

pub fn privileged_export(workspace: &str) -> Result<i32> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "the internal audit helper must run as root"
    );
    let registry = Registry::load_default()?;
    registry.workspace(workspace)?;
    let output = Command::new("journalctl")
        .args([
            "--no-pager",
            "--output=json",
            "--reverse",
            "--lines",
            &MAX_SOURCE_RECORDS.to_string(),
            "--unit",
            "seter-proxy.service",
            "--unit",
            &format!("seter-dns-{workspace}.service"),
        ])
        .output()
        .context("failed to read the policy service journal")?;
    ensure!(
        output.status.success(),
        "journalctl failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    for line in output
        .stdout
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        if let Some(record) = parse_journal_record(line, workspace)? {
            println!("{}", serde_json::to_string(&record)?);
        }
    }
    let workspace_config = registry.workspace(workspace)?;
    let kernel = Command::new("journalctl")
        .args([
            "--no-pager",
            "--output=json",
            "--reverse",
            "--lines",
            &MAX_SOURCE_RECORDS.to_string(),
            "--dmesg",
        ])
        .output()
        .context("failed to read direct-TCP policy observations")?;
    ensure!(
        kernel.status.success(),
        "journalctl failed: {}",
        String::from_utf8_lossy(&kernel.stderr).trim()
    );
    for line in kernel
        .stdout
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        if let Some(record) =
            parse_kernel_record(line, &workspace_config.network.address.to_string())?
        {
            println!("{}", serde_json::to_string(&record)?);
        }
    }
    Ok(0)
}

fn parse_kernel_record(line: &[u8], address: &str) -> Result<Option<AuditRecord>> {
    let journal: Value =
        serde_json::from_slice(line).context("journalctl emitted invalid kernel JSON")?;
    let timestamp_micros = journal
        .get("__REALTIME_TIMESTAMP")
        .and_then(Value::as_str)
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let Some(message) = journal.get("MESSAGE").and_then(Value::as_str) else {
        return Ok(None);
    };
    let prefix = format!("seter-tcp {address} ");
    let Some(rest) = message.split_once(&prefix).map(|(_, rest)| rest) else {
        return Ok(None);
    };
    let decision = if rest.starts_with("allow ") {
        "allow"
    } else if rest.starts_with("deny ") {
        "deny"
    } else {
        return Ok(None);
    };
    let fields = rest
        .split_ascii_whitespace()
        .filter_map(|field| field.split_once('='))
        .collect::<BTreeMap<_, _>>();
    let destination = fields.get("DST").map(|value| (*value).to_owned());
    let port = fields.get("DPT").and_then(|value| value.parse().ok());
    Ok(Some(AuditRecord {
        timestamp_micros,
        boundary: "direct-tcp".to_owned(),
        decision: decision.to_owned(),
        destination,
        port,
        protocol: Some("tcp".to_owned()),
        method: None,
        reason: if decision == "allow" {
            "exact host address and port are active"
        } else {
            "destination is not in the active direct-TCP policy"
        }
        .to_owned(),
        path: None,
    }))
}

fn parse_journal_record(line: &[u8], workspace: &str) -> Result<Option<AuditRecord>> {
    let journal: Value = serde_json::from_slice(line).context("journalctl emitted invalid JSON")?;
    let timestamp_micros = journal
        .get("__REALTIME_TIMESTAMP")
        .and_then(Value::as_str)
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let Some(message) = journal.get("MESSAGE").and_then(Value::as_str) else {
        return Ok(None);
    };
    let (boundary, raw) =
        if let Some(raw) = message.split_once("seter-dns-audit ").map(|(_, raw)| raw) {
            ("dns", raw)
        } else if let Some(raw) = message.split_once("seter-audit ").map(|(_, raw)| raw) {
            ("proxy", raw)
        } else {
            return Ok(None);
        };
    let value: Value = match serde_json::from_str(raw) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    if value.get("workspace").and_then(Value::as_str) != Some(workspace) {
        return Ok(None);
    }
    if value.get("event").is_some() {
        return Ok(None);
    }
    let protocol = value
        .get("protocol")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let effective_boundary = match protocol.as_deref() {
        Some("tls-passthrough") => "tls-passthrough",
        Some("tls") => "tls",
        _ if boundary == "dns" => "dns",
        _ => "http",
    };
    Ok(Some(AuditRecord {
        timestamp_micros,
        boundary: effective_boundary.to_owned(),
        decision: value
            .get("decision")
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_owned(),
        destination: value
            .get("host")
            .or_else(|| value.get("name"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned),
        port: value
            .get("port")
            .and_then(Value::as_u64)
            .and_then(|port| u16::try_from(port).ok()),
        protocol,
        method: value
            .get("method")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
        reason: value
            .get("reason")
            .and_then(Value::as_str)
            .unwrap_or("unspecified policy decision")
            .to_owned(),
        path: value
            .get("path")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned),
    }))
}

fn parse_duration(value: &str) -> Result<Duration> {
    let (number, multiplier) = if let Some(number) = value.strip_suffix('m') {
        (number, 60)
    } else if let Some(number) = value.strip_suffix('h') {
        (number, 3600)
    } else if let Some(number) = value.strip_suffix('d') {
        (number, 86400)
    } else if let Some(number) = value.strip_suffix('s') {
        (number, 1)
    } else {
        bail!("invalid --since duration {value:?}; use forms such as 30m, 2h, or 1d")
    };
    let amount: u64 = number
        .parse()
        .with_context(|| format!("invalid --since duration {value:?}"))?;
    Ok(Duration::from_secs(amount.saturating_mul(multiplier)))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{add_record, parse_duration, AuditCollection, AuditRecord, MAX_GROUPS};
    #[test]
    fn parses_bounded_duration_syntax() {
        assert_eq!(parse_duration("30m").unwrap().as_secs(), 1800);
        assert!(parse_duration("yesterday").is_err());
    }

    #[test]
    fn filters_before_grouping_and_truncates_floods() {
        let mut observations = AuditCollection {
            groups: BTreeMap::new(),
            truncated: false,
        };
        let record = |index: usize, timestamp_micros| AuditRecord {
            timestamp_micros,
            boundary: "dns".to_owned(),
            decision: "deny".to_owned(),
            destination: Some(format!("host-{index}.example.com")),
            port: None,
            protocol: Some("udp".to_owned()),
            method: None,
            reason: "denied".to_owned(),
            path: None,
        };

        add_record(&mut observations, record(0, 1), Some(2)).unwrap();
        assert!(observations.groups.is_empty());
        for index in 0..=MAX_GROUPS {
            add_record(&mut observations, record(index, 2), Some(2)).unwrap();
        }
        assert_eq!(observations.groups.len(), MAX_GROUPS);
        assert!(observations.truncated);
    }
}
