//! Loopback reverse proxy that injects the app-generated Web UI credentials.
//!
//! The official Resilio Web UI (which this app embeds) is protected by HTTP
//! basic auth. A webview cannot pre-fill basic credentials, so SyncPilot
//! serves the official UI through a second loopback-only listener that adds
//! the `Authorization` header on every request. The user gets the official
//! UI without ever seeing a login prompt; the real daemon port never serves
//! an unauthenticated request.

use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::header::{
    AUTHORIZATION, CONNECTION, HOST, PROXY_AUTHORIZATION, TE, TRANSFER_ENCODING, UPGRADE,
};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Uri};
use axum::response::Response;
use axum::routing::any;
use axum::Router;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use reqwest::Client;
use std::sync::{Arc, RwLock};

/// Credentials + upstream target, refreshed when app settings change.
#[derive(Clone)]
pub struct ProxyConfig {
    /// Upstream Web UI port on 127.0.0.1.
    pub daemon_port: u16,
    pub login: String,
    pub password: String,
}

impl ProxyConfig {
    fn authorization_header(&self) -> Option<HeaderValue> {
        let creds = BASE64.encode(format!("{}:{}", self.login, self.password));
        HeaderValue::from_str(&format!("Basic {creds}")).ok()
    }
}

pub struct ProxyHandle {
    /// Local URL the webview should load, e.g. `http://127.0.0.1:45123/gui/`.
    pub base_url: String,
    config: Arc<RwLock<ProxyConfig>>,
}

impl ProxyHandle {
    pub fn update_config(&self, config: ProxyConfig) {
        *self.config.write().unwrap() = config;
    }
}

/// Hop-by-hop headers that must not be forwarded by a proxy.
const STRIP_REQUEST: &[HeaderName] = &[
    HOST,
    CONNECTION,
    TRANSFER_ENCODING,
    UPGRADE,
    TE,
    PROXY_AUTHORIZATION,
];

/// Headers SyncPilot sets itself; incoming versions of these are dropped.
const STRIP_RESPONSE: &[HeaderName] = &[CONNECTION, TRANSFER_ENCODING, UPGRADE];

/// Spawn the proxy on an ephemeral loopback port. The listener lives on the
/// caller's async runtime; dropping the runtime takes it down with the app.
pub async fn spawn(config: ProxyConfig) -> Result<ProxyHandle, String> {
    let config = Arc::new(RwLock::new(config));
    let http = Client::builder()
        // Credentials are injected here; never follow upstream redirects on
        // our own (the official UI issues none, and a followed redirect would
        // lose the injected auth header).
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| format!("proxy http client: {e}"))?;

    let app = Router::new()
        .route("/{*path}", any(forward))
        .fallback(forward)
        .with_state(StateCtx {
            config: Arc::clone(&config),
            http,
        });

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("proxy bind: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("proxy local addr: {e}"))?
        .port();

    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    Ok(ProxyHandle {
        base_url: format!("http://127.0.0.1:{port}"),
        config,
    })
}

#[derive(Clone)]
struct StateCtx {
    config: Arc<RwLock<ProxyConfig>>,
    http: Client,
}

async fn forward(State(ctx): State<StateCtx>, uri: Uri, request: Request) -> Response {
    let config = ctx.config.read().unwrap().clone();
    let path = uri.path();
    // Everything the app serves lives under /gui/; a bare request to the
    // proxy root is redirected there like the daemon does.
    let target = if path == "/" {
        format!("http://127.0.0.1:{}/gui/", config.daemon_port)
    } else {
        let query = uri.query().map(|q| format!("?{q}")).unwrap_or_default();
        format!("http://127.0.0.1:{}{path}{query}", config.daemon_port)
    };

    let (parts, body) = request.into_parts();
    let mut upstream = ctx.http.request(parts.method.clone(), &target);
    let mut headers = HeaderMap::new();
    for (name, value) in parts.headers.iter() {
        if STRIP_REQUEST.contains(name) || name == AUTHORIZATION {
            continue;
        }
        headers.append(name, value.clone());
    }
    if let Some(auth) = config.authorization_header() {
        headers.insert(AUTHORIZATION, auth);
    }
    upstream = upstream.headers(headers);

    let body_bytes = match axum::body::to_bytes(body, 64 * 1024 * 1024).await {
        Ok(b) => b,
        Err(e) => return error_response(400, format!("proxy body read: {e}")),
    };
    let resp = match upstream.body(body_bytes.to_vec()).send().await {
        Ok(r) => r,
        Err(e) => {
            return error_response(
                502,
                format!(
                    "daemon not reachable on 127.0.0.1:{}: {e}",
                    config.daemon_port
                ),
            )
        }
    };

    let status = resp.status();
    let mut out = Response::builder().status(status.as_u16());
    for (name, value) in resp.headers().iter() {
        if STRIP_RESPONSE.contains(name) {
            continue;
        }
        out = out.header(name, value);
    }
    match resp.bytes().await {
        Ok(bytes) => out
            .body(Body::from(bytes))
            .unwrap_or_else(|_| error_response(502, "proxy body assemble failed".into())),
        Err(e) => error_response(502, format!("proxy body read: {e}")),
    }
}

fn error_response(code: u16, message: String) -> Response {
    Response::builder()
        .status(code)
        .header("content-type", "text/plain; charset=utf-8")
        .body(Body::from(message))
        .expect("static error response builds")
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD as B64;

    /// A bare tokio test server standing in for the daemon: it answers 200
    /// only when basic auth matches, echoing back what it saw.
    async fn spawn_upstream() -> (u16, Arc<std::sync::Mutex<Vec<String>>>) {
        use axum::extract::Request;
        let seen: Arc<std::sync::Mutex<Vec<String>>> = Default::default();
        let seen2 = Arc::clone(&seen);
        let app = Router::new().fallback(async move |req: Request| {
            let auth = req
                .headers()
                .get(AUTHORIZATION)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let target = req
                .uri()
                .path_and_query()
                .map(|pq| pq.to_string())
                .unwrap_or_else(|| req.uri().path().to_string());
            seen2.lock().unwrap().push(format!("{target} {auth}"));
            axum::http::Response::builder()
                .header("set-cookie", "rslsess=abc")
                .header("content-type", "text/html")
                .body(format!("path={target}"))
                .unwrap()
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        (port, seen)
    }

    #[tokio::test]
    async fn injects_credentials_and_forwards() {
        let (upstream_port, seen) = spawn_upstream().await;
        let handle = spawn(ProxyConfig {
            daemon_port: upstream_port,
            login: "syncpilot".into(),
            password: "hunter2".into(),
        })
        .await
        .expect("proxy spawns");

        let http = Client::new();
        // Bare root must redirect-serve /gui/ with injected auth.
        let resp = http
            .get(format!("{}/", handle.base_url))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        let text = resp.text().await.unwrap();
        assert!(text.contains("path=/gui/"), "got: {text}");
        // Query strings survive; /gui/?token=… is the action surface.
        let resp = http
            .get(format!("{}/gui/?token=x&action=version", handle.base_url))
            .send()
            .await
            .unwrap();
        assert!(resp.text().await.unwrap().contains("action=version"));
        // Response headers (Set-Cookie for the session) pass through.
        let resp = http
            .get(format!("{}/gui/", handle.base_url))
            .send()
            .await
            .unwrap();
        assert_eq!(
            resp.headers()
                .get_all("set-cookie")
                .iter()
                .filter(|v| v.to_str().unwrap().contains("rslsess"))
                .count(),
            1
        );

        let expected = format!("Basic {}", B64.encode("syncpilot:hunter2"));
        let seen = seen.lock().unwrap();
        assert!(
            seen.iter().all(|entry| {
                entry.split_once(' ').map(|(_, auth)| auth) == Some(expected.as_str())
            }),
            "every upstream request must carry injected auth: {seen:?}"
        );
    }

    #[tokio::test]
    async fn update_config_changes_upstream() {
        let (port_a, _seen) = spawn_upstream().await;
        let handle = spawn(ProxyConfig {
            daemon_port: port_a,
            login: "u".into(),
            password: "p".into(),
        })
        .await
        .unwrap();
        handle.update_config(ProxyConfig {
            daemon_port: port_a,
            login: "u2".into(),
            password: "p2".into(),
        });
        let resp = Client::new()
            .get(format!("{}/gui/", handle.base_url))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
    }
}
