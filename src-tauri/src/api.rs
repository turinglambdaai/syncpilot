//! Minimal client for the rslsync Web UI "action" API.
//!
//! SyncPilot embeds the official Web UI (served through the auth-injecting
//! proxy in `proxy.rs`), so this client only needs the lifecycle calls:
//! health checks, version and graceful shutdown. Protocol facts are in
//! `docs/api-verified.md`:
//!
//! - HTTP basic auth on every request (`WWW-Authenticate: Basic`).
//! - `POST /gui/token.html` returns a CSRF token inside an HTML div
//!   (`>([^<]+)<`); it is bound to the HTTP session (cookie jar).
//! - `GET /gui/?token=…&action=…` replies `{"status":200,"value":…}` on
//!   success, HTTP 400 + `invalid request` for a stale token (retry once
//!   with a fresh one), HTTP 500 + `{"error":…}` for business errors.

use serde_json::Value;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const EP_TOKEN: &str = "/gui/token.html";
const EP_ACTION: &str = "/gui/";

/// Outcome of probing the configured Web UI port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PortProbe {
    /// A daemon answered and accepted our credentials — ours to drive.
    Compatible,
    /// Something answered but rejected our credentials: a foreign daemon
    /// (often a leftover system service running as another user) owns the
    /// port. Must be reported, never adopted.
    Foreign,
    /// Nothing answered.
    Unreachable,
}

#[derive(Clone)]
pub struct ResilioClient {
    base: Arc<String>,
    login: Arc<String>,
    password: Arc<String>,
    http: reqwest::Client,
    /// CSRF token from token.html, reused until the daemon rejects it.
    token: Arc<std::sync::Mutex<Option<String>>>,
}

impl ResilioClient {
    pub fn new(port: u16, login: &str, password: &str) -> Self {
        let http = reqwest::Client::builder()
            .cookie_store(true)
            .timeout(Duration::from_secs(8))
            .build()
            .expect("reqwest client builds");
        Self {
            base: Arc::new(format!("http://127.0.0.1:{port}")),
            login: Arc::new(login.to_string()),
            password: Arc::new(password.to_string()),
            http,
            token: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    /// Probe the configured Web UI port. Adopting a daemon requires
    /// `Compatible`: a 401 means a foreign daemon (often a leftover systemd
    /// service running as a different user) owns the port and must be
    /// reported, never adopted — driving it would be impossible and it may
    /// lack the user's own file permissions.
    pub async fn probe_port(&self) -> PortProbe {
        match self
            .http
            .get(format!("{}{EP_ACTION}", self.base))
            .basic_auth(self.login.as_str(), Some(self.password.as_str()))
            .send()
            .await
        {
            Ok(r) if r.status().is_success() => PortProbe::Compatible,
            Ok(r) if matches!(r.status().as_u16(), 401 | 403) => PortProbe::Foreign,
            _ => PortProbe::Unreachable,
        }
    }

    /// POST /gui/token.html and pull the CSRF token out of the HTML wrapper
    /// (`<div id='token' …>TOKEN</div>`).
    async fn fetch_token(&self) -> Result<String, String> {
        let resp = self
            .http
            .post(format!("{}{EP_TOKEN}", self.base))
            .basic_auth(self.login.as_str(), Some(self.password.as_str()))
            .query(&[("t", millis_now().to_string())])
            .send()
            .await
            .map_err(|e| format!("token request failed: {e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("token body read failed: {e}"))?;
        if status.as_u16() == 401 {
            return Err("basic auth rejected (check webui credentials)".into());
        }
        if !status.is_success() {
            return Err(format!("token request -> HTTP {status}"));
        }
        extract_token(&text)
            .ok_or_else(|| format!("token response has no token payload: {text:.100}"))
    }

    async fn token_or_refresh(&self, force: bool) -> Result<String, String> {
        if !force {
            if let Some(t) = self.token.lock().unwrap().clone() {
                return Ok(t);
            }
        }
        let t = self.fetch_token().await?;
        *self.token.lock().unwrap() = Some(t.clone());
        Ok(t)
    }

    fn invalidate_token(&self) {
        *self.token.lock().unwrap() = None;
    }

    /// Run one action and return its `value` payload (or the bare object for
    /// actions that reply without a `value` wrapper). Retries once with a
    /// fresh token when the daemon reports the current one invalid.
    async fn action(&self, action: &str, params: &[(&str, &str)]) -> Result<Value, String> {
        for retry in [false, true] {
            let token = self.token_or_refresh(retry).await?;
            let url = format!("{}{EP_ACTION}", self.base);
            let mut query: Vec<(&str, String)> = vec![
                ("token", token),
                ("action", action.to_string()),
                ("t", millis_now().to_string()),
            ];
            for (k, v) in params {
                query.push((k, (*v).to_string()));
            }
            let resp = self
                .http
                .get(&url)
                .basic_auth(self.login.as_str(), Some(self.password.as_str()))
                .query(&query)
                .send()
                .await
                .map_err(|e| format!("action {action} failed: {e}"))?;
            let status = resp.status().as_u16();
            let text = resp
                .text()
                .await
                .map_err(|e| format!("action {action} body read failed: {e}"))?;
            if status == 400 && text.contains("invalid request") {
                self.invalidate_token();
                continue;
            }
            if status == 401 {
                return Err("basic auth rejected (check webui credentials)".into());
            }
            if !(200..300).contains(&status) {
                // rslsync reports business errors as HTTP 500 + JSON envelope.
                if let Ok(v) = serde_json::from_str::<Value>(&text) {
                    if let Some(msg) = error_message(&v) {
                        return Err(format!("{action}: {msg}"));
                    }
                }
                return Err(format!("{action} -> HTTP {status}: {text:.200}"));
            }
            let v: Value = serde_json::from_str(&text)
                .map_err(|e| format!("action {action} non-JSON response: {e}"))?;
            if let Some(msg) = error_message(&v) {
                return Err(format!("{action}: {msg}"));
            }
            return Ok(v.get("value").cloned().unwrap_or(v));
        }
        Err(format!("{action}: daemon keeps rejecting the CSRF token"))
    }

    /// Daemon version string, e.g. `3.1.2 (1076)`.
    pub async fn version(&self) -> Result<String, String> {
        let v = self.action("version", &[]).await?;
        Ok(v.as_str().unwrap_or_default().to_string())
    }

    pub async fn shutdown(&self) -> Result<(), String> {
        self.action("shutdown", &[]).await.map(|_| ())
    }
}

fn millis_now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// The token.html body wraps the token in HTML tags; the official Web UI
/// matches `>([^<]+)<`. Walk tag pairs from the end: the `</html>` pair
/// yields an empty payload and is skipped, the innermost pair holds the
/// token.
fn extract_token(body: &str) -> Option<String> {
    body.rmatch_indices('<').find_map(|(end, _)| {
        let start = body[..end].rfind('>')?;
        let tok = &body[start + 1..end];
        (!tok.is_empty()).then(|| tok.to_string())
    })
}

/// Top-level envelope error `{"error":"msg","status":500}`.
fn error_message(v: &Value) -> Option<String> {
    let err = v.get("error")?;
    match err {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => {
            let msg = v
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error");
            Some(format!("{msg} ({n})"))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn extracts_token_from_html_wrapper() {
        let body = "<html><div id='token' style='display:none;'>7QAlANw_Q9z6FT_AzWZNKya-vQU2mUiFcXMfSqA-Q2-bwOZW4cR2r05IumoAAAAA</div></html>";
        assert_eq!(
            extract_token(body).as_deref(),
            Some("7QAlANw_Q9z6FT_AzWZNKya-vQU2mUiFcXMfSqA-Q2-bwOZW4cR2r05IumoAAAAA")
        );
        // No tag pairs → no token payload.
        assert_eq!(extract_token("invalid request"), None);
        assert_eq!(extract_token(""), None);
    }

    #[test]
    fn error_envelopes_are_recognized() {
        let top = json!({"error": "can't find folder by folderid", "status": 500});
        assert_eq!(
            error_message(&top).as_deref(),
            Some("can't find folder by folderid")
        );
        let nested = json!({"error": 205, "message": "SE_SM_NO_IDENTITY"});
        assert_eq!(
            error_message(&nested).as_deref(),
            Some("SE_SM_NO_IDENTITY (205)")
        );
        assert_eq!(error_message(&json!({"status": 200})), None);
    }

    // ---- end-to-end against a tiny loopback HTTP mock ----

    /// Minimal loopback HTTP mock standing in for rslsync's Web UI server.
    /// Serves token.html and the /gui/?token=…&action=… surface with the
    /// verified envelope semantics (400 `invalid request` on a bad token).
    fn spawn_mock(routes: Vec<(&'static str, u16, String)>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = match stream {
                    Ok(s) => s,
                    Err(_) => break,
                };
                let mut buf = [0u8; 16384];
                let n = stream.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let (method, target) = {
                    let mut it = req.lines().next().unwrap_or("").split(' ');
                    (it.next().unwrap_or(""), it.next().unwrap_or(""))
                };
                let path = target.split('?').next().unwrap_or("");
                let query = target.split_once('?').map(|(_, q)| q).unwrap_or("");
                let mut params: Vec<(String, String)> = Vec::new();
                for kv in query.split('&').filter(|s| !s.is_empty()) {
                    let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                    params.push((k.to_string(), v.to_string()));
                }
                let get = |name: &str| {
                    params
                        .iter()
                        .find(|(k, _)| k == name)
                        .map(|(_, v)| v.clone())
                };
                let (code, body) = if path == EP_TOKEN && method == "POST" {
                    (
                        200,
                        "<html><div id='token' style='display:none;'>TOK123</div></html>"
                            .to_string(),
                    )
                } else if path == EP_ACTION {
                    match (get("token").as_deref(), get("action")) {
                        (Some("TOK123"), _) => {
                            let action = get("action").unwrap_or_default();
                            routes
                                .iter()
                                .find(|(a, _, _)| *a == action)
                                .map(|(_, c, b)| (*c, b.clone()))
                                .unwrap_or((
                                    404,
                                    "{\"error\":\"unknown action\",\"status\":404}".into(),
                                ))
                        }
                        // Bare GET /gui/ is the Web UI page itself: the
                        // daemon answers 200 with valid basic auth.
                        (None, None) => (200, "{}".into()),
                        _ => (400, "invalid request".into()),
                    }
                } else {
                    (404, "not found".into())
                };
                let resp = format!(
                    "HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes());
            }
        });
        port
    }

    #[tokio::test]
    async fn end_to_end_ping_version_and_shutdown() {
        let port = spawn_mock(vec![
            (
                "version",
                200,
                json!({"status":200,"value":"3.1.2 (1076)"}).to_string(),
            ),
            ("shutdown", 200, json!({"status":200}).to_string()),
        ]);
        let c = ResilioClient::new(port, "u", "p");
        assert_eq!(
            c.probe_port().await,
            PortProbe::Compatible,
            "mock must answer on its port"
        );

        let v = c.version().await.expect("version");
        assert_eq!(v, "3.1.2 (1076)");

        // Business errors (HTTP 500 + envelope) become Err with the message.
        let err = c.action("nope", &[]).await.unwrap_err();
        assert!(err.contains("unknown action"), "got: {err}");

        c.shutdown().await.expect("shutdown");
    }

    /// One-shot listener answering every request with a fixed status.
    async fn spawn_status_listener(status: u16) -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let resp = format!(
                    "HTTP/1.1 {status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
                use tokio::io::AsyncWriteExt;
                let _ = stream.write_all(resp.as_bytes()).await;
            }
        });
        port
    }

    #[tokio::test]
    async fn probe_port_distinguishes_compatible_foreign_and_absent() {
        // Compatible: 200 on the Web UI surface.
        let ok = spawn_status_listener(200).await;
        let c = ResilioClient::new(ok, "u", "p");
        assert_eq!(c.probe_port().await, PortProbe::Compatible);

        // Foreign: a daemon that rejects our credentials (basic auth 401) —
        // the regression case that used to be adopted blindly.
        let unauthorized = spawn_status_listener(401).await;
        let c = ResilioClient::new(unauthorized, "u", "p");
        assert_eq!(c.probe_port().await, PortProbe::Foreign);

        let forbidden = spawn_status_listener(403).await;
        let c = ResilioClient::new(forbidden, "u", "p");
        assert_eq!(c.probe_port().await, PortProbe::Foreign);

        // Unreachable: bind a port, drop the listener, then probe it.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let c = ResilioClient::new(port, "u", "p");
        assert_eq!(c.probe_port().await, PortProbe::Unreachable);
    }
}
