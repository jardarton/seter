use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    os::unix::net::UnixStream,
    path::Path,
    time::Duration,
};

use anyhow::{ensure, Context, Result};

const LIMIT: usize = 256 * 1024;
const TIMEOUT: Duration = Duration::from_secs(3);

pub fn browser(port: u16, expected_path: Option<&str>) -> Result<String> {
    ensure!(port != 0, "CDP port cannot be zero");
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream =
        TcpStream::connect_timeout(&address, TIMEOUT).context("CDP endpoint is unreachable")?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    let body = request(&mut stream, "/json/version")?;
    let response: serde_json::Value =
        serde_json::from_slice(&body).context("invalid CDP version response")?;
    let url = response["webSocketDebuggerUrl"]
        .as_str()
        .context("CDP endpoint has no browser WebSocket URL")?;
    let path = websocket_path(url)?;
    if let Some(expected) = expected_path {
        ensure!(
            path == expected,
            "Chrome endpoint changed; attach the browser again"
        );
    }
    Ok(path.into())
}

pub fn docker(socket: &Path) -> Result<()> {
    let mut stream = UnixStream::connect(socket).context("Docker socket is unreachable")?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    let body = request(&mut stream, "/_ping")?;
    ensure!(body == b"OK", "socket does not answer the Docker API ping");
    Ok(())
}

pub fn websocket_path(url: &str) -> Result<&str> {
    let remainder = url
        .strip_prefix("ws://")
        .context("CDP URL must use ws://")?;
    let (authority, path) = remainder
        .split_once('/')
        .context("invalid CDP WebSocket URL")?;
    let (host, port) = authority.rsplit_once(':').context("CDP URL has no port")?;
    ensure!(
        matches!(host, "127.0.0.1" | "localhost" | "[::1]"),
        "CDP endpoint must be loopback-only"
    );
    ensure!(
        port.parse::<u16>().is_ok_and(|port| port > 0),
        "invalid CDP URL port"
    );
    validate_path(&format!("/{path}"))?;
    Ok(&url[url.len() - path.len() - 1..])
}

pub fn validate_path(path: &str) -> Result<()> {
    let identity = path
        .strip_prefix("/devtools/browser/")
        .context("invalid browser WebSocket path")?;
    ensure!(
        !identity.is_empty()
            && identity.len() <= 200
            && identity
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)),
        "invalid browser WebSocket identity"
    );
    Ok(())
}

fn request(stream: &mut (impl Read + Write), path: &str) -> Result<Vec<u8>> {
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    )?;
    let mut response = Vec::new();
    let mut buffer = [0_u8; 4096];
    loop {
        let count = stream
            .read(&mut buffer)
            .context("endpoint response timed out or failed")?;
        if count == 0 {
            break;
        }
        response.extend_from_slice(&buffer[..count]);
        ensure!(response.len() <= LIMIT, "endpoint response is too large");
        if let Some((headers, body)) = split_response(&response) {
            if let Some(length) = content_length(headers)? {
                ensure!(length <= LIMIT, "endpoint response is too large");
                if body.len() >= length {
                    break;
                }
            } else if headers
                .to_ascii_lowercase()
                .contains("transfer-encoding: chunked")
                && decode_chunks(body)?.is_some()
            {
                break;
            }
        }
    }
    let (headers, body) = split_response(&response).context("invalid HTTP response")?;
    let status = headers
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .nth(1);
    ensure!(
        status == Some("200"),
        "endpoint returned HTTP {}",
        status.unwrap_or("invalid")
    );
    if headers
        .to_ascii_lowercase()
        .contains("transfer-encoding: chunked")
    {
        decode_chunks(body)?.context("truncated chunked HTTP response")
    } else if let Some(length) = content_length(headers)? {
        ensure!(body.len() >= length, "truncated HTTP response");
        Ok(body[..length].to_vec())
    } else {
        Ok(body.to_vec())
    }
}

fn split_response(response: &[u8]) -> Option<(&str, &[u8])> {
    let split = response.windows(4).position(|bytes| bytes == b"\r\n\r\n")?;
    Some((
        std::str::from_utf8(&response[..split]).ok()?,
        &response[split + 4..],
    ))
}

fn content_length(headers: &str) -> Result<Option<usize>> {
    for line in headers.lines().skip(1) {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                return Ok(Some(
                    value
                        .trim()
                        .parse()
                        .context("invalid HTTP content length")?,
                ));
            }
        }
    }
    Ok(None)
}

fn decode_chunks(mut input: &[u8]) -> Result<Option<Vec<u8>>> {
    let mut body = Vec::new();
    loop {
        let Some(end) = input.windows(2).position(|bytes| bytes == b"\r\n") else {
            return Ok(None);
        };
        let size = std::str::from_utf8(&input[..end])?
            .split(';')
            .next()
            .unwrap_or("");
        let size = usize::from_str_radix(size.trim(), 16).context("invalid HTTP chunk")?;
        ensure!(size <= LIMIT - body.len(), "endpoint response is too large");
        input = &input[end + 2..];
        if size == 0 {
            return Ok(input.starts_with(b"\r\n").then_some(body));
        }
        if input.len() < size + 2 {
            return Ok(None);
        }
        ensure!(
            &input[size..size + 2] == b"\r\n",
            "invalid HTTP chunk terminator"
        );
        body.extend_from_slice(&input[..size]);
        input = &input[size + 2..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browser_urls_cannot_select_external_hosts_or_arbitrary_paths() {
        for url in [
            "ws://example.invalid:9222/devtools/browser/abc",
            "ws://127.0.0.1:0/devtools/browser/abc",
            "ws://127.0.0.1:9222/devtools/page/abc",
            "ws://127.0.0.1:9222/devtools/browser/abc?token=secret",
        ] {
            assert!(websocket_path(url).is_err(), "{url}");
        }
        assert_eq!(
            websocket_path("ws://localhost:9222/devtools/browser/abc-123").unwrap(),
            "/devtools/browser/abc-123"
        );
    }

    #[test]
    fn http_checks_status_length_and_chunk_boundaries() {
        struct Stream {
            input: std::io::Cursor<Vec<u8>>,
        }
        impl Read for Stream {
            fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
                self.input.read(buffer)
            }
        }
        impl Write for Stream {
            fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
                Ok(buffer.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        for (response, valid) in [
            ("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK", true),
            (
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nOK\r\n0\r\n\r\n",
                true,
            ),
            ("HTTP/1.1 403 Denied\r\nContent-Length: 2\r\n\r\nOK", false),
            ("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nOK", false),
        ] {
            let result = request(
                &mut Stream {
                    input: std::io::Cursor::new(response.as_bytes().to_vec()),
                },
                "/_ping",
            );
            assert_eq!(result.is_ok(), valid);
        }
    }
}
