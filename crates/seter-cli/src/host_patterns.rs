//! Exact host and single-label Host Pattern validation.

use std::{collections::BTreeSet, net::Ipv4Addr, sync::OnceLock};

use anyhow::{ensure, Context, Result};

const PUBLIC_SUFFIX_LIST: &str = include_str!("../data/public_suffix_list.dat");

pub fn validate_host_pattern(pattern: &str) -> Result<()> {
    let normalized = pattern.to_ascii_lowercase();
    let pattern = normalized.as_str();
    ensure!(
        pattern.len() <= 253,
        "Host Patterns must not exceed 253 characters"
    );
    if let Some(suffix) = pattern.strip_prefix("*.") {
        validate_exact_host(suffix)?;
        ensure!(
            suffix.parse::<Ipv4Addr>().is_err(),
            "wildcards cannot name literal IPv4 addresses"
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

pub(crate) fn validate_exact_host(host: &str) -> Result<()> {
    if host
        .bytes()
        .all(|byte| byte.is_ascii_digit() || byte == b'.')
    {
        host.parse::<Ipv4Addr>()
            .context("numeric hosts must be canonical dotted-decimal IPv4 addresses")?;
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
        || rules.contains(format!("*.{suffix}").as_str())
        || suffix
            .split_once('.')
            .is_some_and(|(_, parent)| rules.contains(format!("*.{parent}").as_str()))
}

fn pattern_matches(pattern: &str, host: &str) -> bool {
    if validate_exact_host(host).is_err() {
        return false;
    }
    let pattern = pattern.to_ascii_lowercase();
    let host = host.to_ascii_lowercase();
    pattern == host
        || pattern.strip_prefix("*.").is_some_and(|suffix| {
            host.split_once('.')
                .is_some_and(|(first, remainder)| !first.is_empty() && remainder == suffix)
        })
}

pub fn patterns_overlap(left: &str, right: &str) -> bool {
    left.eq_ignore_ascii_case(right) || pattern_matches(left, right) || pattern_matches(right, left)
}

#[cfg(test)]
mod tests {
    use serde::Deserialize;

    use super::*;

    #[test]
    fn follows_shared_host_pattern_contract() {
        #[derive(Deserialize)]
        struct HostCase {
            label: String,
            input: String,
            exact: bool,
            pattern: bool,
            canonical: Option<String>,
        }
        #[derive(Deserialize)]
        struct MatchCase {
            pattern: String,
            host: String,
            matches: bool,
        }
        #[derive(Deserialize)]
        struct OverlapCase {
            left: String,
            right: String,
            overlaps: bool,
        }
        #[derive(Deserialize)]
        struct Cases {
            hosts: Vec<HostCase>,
            matches: Vec<MatchCase>,
            overlaps: Vec<OverlapCase>,
        }
        let cases: Cases =
            serde_json::from_str(include_str!("../data/host-pattern-cases.json")).unwrap();
        for case in cases.hosts {
            assert_eq!(
                validate_exact_host(&case.input).is_ok(),
                case.exact,
                "exact: {}",
                case.label
            );
            assert_eq!(
                validate_host_pattern(&case.input).is_ok(),
                case.pattern,
                "pattern: {}",
                case.label
            );
            if let Some(canonical) = case.canonical {
                assert_eq!(case.input.to_ascii_lowercase(), canonical);
            }
        }
        for case in cases.matches {
            assert_eq!(
                pattern_matches(&case.pattern, &case.host),
                case.matches,
                "{} matching {}",
                case.pattern,
                case.host
            );
        }
        for case in cases.overlaps {
            assert_eq!(
                patterns_overlap(&case.left, &case.right),
                case.overlaps,
                "{} overlapping {}",
                case.left,
                case.right
            );
        }
    }
}
