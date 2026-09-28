//! Async client for the local Resilio Sync (rslsync) Web UI v2 API.
//!
//! All endpoint paths live in this module on purpose: rslsync has field drift
//! between builds, so responses are parsed leniently — anything absent or of
//! an unexpected shape degrades to `None`/defaults instead of an error. If a
//! future rslsync release renames an endpoint, this is the one file to fix.

use serde::Serialize;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

const EP_LOGIN: &str = "/api/v2/auth/login";
const EP_STATUS: &str = "/api/v2/status";
const EP_FOLDERS: &str = "/api/v2/folders";
const EP_FOLDER_ADD: &str = "/api/v2/folders/add_folder";
const EP_FOLDER_REMOVE: &str = "/api/v2/folders/remove";
const EP_FOLDER_PAUSE: &str = "/api/v2/folders/pause";
const EP_FOLDER_RESUME: &str = "/api/v2/folders/resume";
const EP_COMMAND: &str = "/api/v2/command";
const EP_KNOWN_PEERS: &str = "/api/v2/known_peers";
const EP_SECRETS_GENERATE: &str = "/api/v2/secrets/generate";
const EP_PREFS: &str = "/api/v2/prefs";

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct Peer {
    pub id: String,
    pub name: String,
    /// "online" / "offline" on most builds.
    pub status: Option<String>,
    /// "direct" / "relay" / "pex" / ...
    pub connection: Option<String>,
    /// "synced" / "syncing" / "offline" / ...
    pub syncstate: Option<String>,
    pub isreadable: Option<bool>,
    pub iswritable: Option<bool>,
    pub percent_downloaded: Option<f64>,
    pub download: Option<f64>,
    pub upload: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct Folder {
    pub id: String,
    pub secret: String,
    pub path: String,
    pub ispaused: bool,
    /// rslsync reports folder sizes as floats on some builds.
    pub size: Option<f64>,
    pub date_added: Option<u64>,
    /// 2 = read & write, 1 = read only (share level).
    pub synclevel: Option<u8>,
    pub peers: Vec<Peer>,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct KnownPeer {
    pub id: String,
    pub name: String,
    pub clientversion: Option<String>,
    pub os: Option<String>,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct RuntimeStatus {
    /// Bytes per second.
    pub speed_up: f64,
    pub speed_down: f64,
    pub paused: bool,
    pub uptime: Option<u64>,
    pub version: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct GeneratedSecrets {
    /// Read & write key.
    pub secret: String,
    pub read_only: Option<String>,
    pub encryption: Option<String>,
}

#[derive(Clone)]
pub struct ResilioClient {
    base: Arc<String>,
    api_key: Arc<String>,
    login: Arc<String>,
    password: Arc<String>,
    http: reqwest::Client,
}

impl ResilioClient {
    pub fn new(port: u16, api_key: &str, login: &str, password: &str) -> Self {
        let http = reqwest::Client::builder()
            .cookie_store(true)
            .timeout(Duration::from_secs(8))
            .build()
            .expect("reqwest client builds");
        Self {
            base: Arc::new(format!("http://127.0.0.1:{port}")),
            api_key: Arc::new(api_key.to_string()),
            login: Arc::new(login.to_string()),
            password: Arc::new(password.to_string()),
            http,
        }
    }

    fn auth_headers(&self) -> reqwest::header::HeaderMap {
        let mut h = reqwest::header::HeaderMap::new();
        if !self.api_key.is_empty() {
            if let Ok(v) = reqwest::header::HeaderValue::from_str(&self.api_key) {
                h.insert("X-API-Key", v);
            }
        }
        h
    }

    /// Log into the Web UI so the session cookie lands in the cookie jar.
    pub async fn login(&self) -> Result<(), String> {
        let url = format!("{}{EP_LOGIN}", self.base);
        let form = [
            ("username", self.login.as_str()),
            ("password", self.password.as_str()),
        ];
        let resp = self
            .http
            .post(&url)
            .headers(self.auth_headers())
            .form(&form)
            .send()
            .await
            .map_err(|e| format!("login request failed: {e}"))?;
        match resp.status() {
            s if s.is_success() => Ok(()),
            s => Err(format!("login rejected with HTTP {s}")),
        }
    }

    /// True when something answers on the configured loopback port
    /// (401 still means a daemon is there, just unauthenticated).
    pub async fn ping(&self) -> bool {
        matches!(
            self.http
                .get(format!("{}{EP_STATUS}", self.base))
                .headers(self.auth_headers())
                .send()
                .await,
            Ok(r) if r.status().is_success() || r.status().as_u16() == 401
        )
    }

    async fn get_json(&self, path: &str) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        for relogin in [false, true] {
            if relogin {
                self.login().await?;
            }
            let resp = self
                .http
                .get(&url)
                .headers(self.auth_headers())
                .send()
                .await
                .map_err(|e| format!("GET {path} failed: {e}"))?;
            if resp.status().as_u16() == 401 && !relogin {
                continue;
            }
            let status = resp.status();
            let body = resp
                .text()
                .await
                .map_err(|e| format!("GET {path} body read failed: {e}"))?;
            if !status.is_success() {
                return Err(format!("GET {path} -> HTTP {status}"));
            }
            return serde_json::from_str(&body).map_err(|e| format!("GET {path}: bad JSON: {e}"));
        }
        Err(format!("GET {path} still unauthorized after login"))
    }

    async fn post_json(&self, path: &str, body: Value) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        for relogin in [false, true] {
            if relogin {
                self.login().await?;
            }
            let resp = self
                .http
                .post(&url)
                .headers(self.auth_headers())
                .json(&body)
                .send()
                .await
                .map_err(|e| format!("POST {path} failed: {e}"))?;
            if resp.status().as_u16() == 401 && !relogin {
                continue;
            }
            let status = resp.status();
            let text = resp
                .text()
                .await
                .map_err(|e| format!("POST {path} body read failed: {e}"))?;
            if !status.is_success() {
                return Err(format!("POST {path} -> HTTP {status}: {text}"));
            }
            return Ok(serde_json::from_str(&text).unwrap_or(Value::Null));
        }
        Err(format!("POST {path} still unauthorized after login"))
    }

    pub async fn status(&self) -> Result<RuntimeStatus, String> {
        self.get_json(EP_STATUS).await.map(|v| parse_status(&v))
    }

    pub async fn folders(&self) -> Result<Vec<Folder>, String> {
        self.get_json(EP_FOLDERS).await.map(|v| parse_folders(&v))
    }

    pub async fn known_peers(&self) -> Result<Vec<KnownPeer>, String> {
        self.get_json(EP_KNOWN_PEERS)
            .await
            .map(|v| parse_known_peers(&v))
    }

    pub async fn generate_secrets(&self) -> Result<GeneratedSecrets, String> {
        let v = self.get_json(EP_SECRETS_GENERATE).await?;
        parse_secrets(&v).ok_or_else(|| "response contains no secret".to_string())
    }

    pub async fn add_folder(&self, dir: &str, secret: Option<&str>) -> Result<(), String> {
        let mut body = json!({ "dir": dir });
        if let Some(s) = secret {
            if !s.trim().is_empty() {
                body["secret"] = json!(s.trim());
            }
        }
        self.post_json(EP_FOLDER_ADD, body).await.map(|_| ())
    }

    pub async fn remove_folder(&self, id: &str) -> Result<(), String> {
        self.post_json(EP_FOLDER_REMOVE, json!({ "id": id }))
            .await
            .map(|_| ())
    }

    pub async fn pause_folder(&self, id: &str, paused: bool) -> Result<(), String> {
        let ep = if paused {
            EP_FOLDER_PAUSE
        } else {
            EP_FOLDER_RESUME
        };
        self.post_json(ep, json!({ "id": id })).await.map(|_| ())
    }

    pub async fn pause_all(&self, paused: bool) -> Result<(), String> {
        let t = if paused { "pause" } else { "resume" };
        self.post_json(EP_COMMAND, json!({ "type": t }))
            .await
            .map(|_| ())
    }

    pub async fn shutdown(&self) -> Result<(), String> {
        self.post_json(EP_COMMAND, json!({ "type": "shutdown" }))
            .await
            .map(|_| ())
    }

    pub async fn prefs(&self) -> Result<Value, String> {
        self.get_json(EP_PREFS).await
    }

    /// 0 means unlimited, mirroring rslsync semantics.
    pub async fn set_speed_limits(&self, up_kbps: u64, down_kbps: u64) -> Result<(), String> {
        self.post_json(
            EP_PREFS,
            json!({ "rate_limit_up": up_kbps, "rate_limit_down": down_kbps }),
        )
        .await
        .map(|_| ())
    }
}

fn num_f64(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        _ => 0.0,
    }
}

fn str_field(v: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|k| v.get(*k).and_then(Value::as_str))
        .map(str::to_string)
}

fn bool_field(v: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|k| v.get(*k).and_then(Value::as_bool))
}

fn num_field(v: &Value, keys: &[&str]) -> Option<f64> {
    keys.iter()
        .find_map(|k| v.get(*k))
        .map(|x| num_f64(Some(x)))
}

fn u64_field(v: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|k| v.get(*k).and_then(Value::as_u64))
}

pub fn parse_status(v: &Value) -> RuntimeStatus {
    RuntimeStatus {
        speed_up: num_f64(v.get("speed_up")),
        speed_down: num_f64(v.get("speed_down")),
        paused: bool_field(v, &["paused"]).unwrap_or(false),
        uptime: u64_field(v, &["uptime"]),
        version: str_field(v, &["version"]),
    }
}

pub fn parse_folders(v: &Value) -> Vec<Folder> {
    // Both top-level {"folders":[...]} and legacy {"data":{"folders":[...]}}
    // shapes have shipped in different rslsync releases.
    let arr = v
        .get("folders")
        .or_else(|| v.pointer("/data/folders"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    arr.iter()
        .filter_map(|f| {
            let peers = f
                .get("peers")
                .and_then(Value::as_array)
                .map(|ps| ps.iter().map(parse_peer).collect())
                .unwrap_or_default();
            let folder = Folder {
                id: str_field(f, &["id"]).unwrap_or_default(),
                secret: str_field(f, &["secret"]).unwrap_or_default(),
                path: str_field(f, &["path", "dir"]).unwrap_or_default(),
                ispaused: bool_field(f, &["ispaused", "paused"]).unwrap_or(false),
                size: num_field(f, &["size"]),
                date_added: u64_field(f, &["date_added"]),
                synclevel: f.get("synclevel").and_then(Value::as_u64).map(|x| x as u8),
                peers,
            };
            if folder.id.is_empty() && folder.path.is_empty() {
                None
            } else {
                Some(folder)
            }
        })
        .collect()
}

fn parse_peer(p: &Value) -> Peer {
    Peer {
        id: str_field(p, &["id"]).unwrap_or_default(),
        name: str_field(p, &["name"]).unwrap_or_default(),
        status: str_field(p, &["status"]),
        connection: str_field(p, &["connection"]),
        syncstate: str_field(p, &["syncstate"]),
        isreadable: bool_field(p, &["isreadable"]),
        iswritable: bool_field(p, &["iswritable"]),
        percent_downloaded: num_field(p, &["percent_downloaded"]),
        download: num_field(p, &["download"]),
        upload: num_field(p, &["upload"]),
    }
}

pub fn parse_known_peers(v: &Value) -> Vec<KnownPeer> {
    let arr = v
        .get("peers")
        .or_else(|| v.pointer("/data/peers"))
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| v.as_array().cloned())
        .unwrap_or_default();
    arr.iter()
        .map(|p| KnownPeer {
            id: str_field(p, &["id"]).unwrap_or_default(),
            name: str_field(p, &["name"]).unwrap_or_default(),
            clientversion: str_field(p, &["clientversion", "version"]),
            os: str_field(p, &["os", "platform"]),
        })
        .collect()
}

pub fn parse_secrets(v: &Value) -> Option<GeneratedSecrets> {
    let secret = str_field(v, &["secret"])?;
    Some(GeneratedSecrets {
        secret,
        read_only: str_field(v, &["rosecret", "read_only", "ro_secret"]),
        encryption: str_field(v, &["encsecret", "encryption", "enc_secret"]),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_folders_top_level_and_wrapped() {
        let mk = |wrapped: bool| {
            let folder = json!({
                "id": "abc123",
                "secret": "SEC",
                "path": "/home/me/docs",
                "ispaused": true,
                "size": 1234.5,
                "date_added": 1700000000u64,
                "synclevel": 2,
                "peers": [{
                    "id": "p1", "name": "laptop", "status": "online",
                    "connection": "direct", "syncstate": "syncing",
                    "percent_downloaded": 55.0, "download": 1024.0, "upload": 0.0
                }]
            });
            if wrapped {
                json!({ "data": { "folders": [folder] } })
            } else {
                json!({ "folders": [folder] })
            }
        };
        for v in [mk(false), mk(true)] {
            let folders = parse_folders(&v);
            assert_eq!(folders.len(), 1);
            let f = &folders[0];
            assert_eq!(f.id, "abc123");
            assert_eq!(f.path, "/home/me/docs");
            assert!(f.ispaused);
            assert_eq!(f.size, Some(1234.5));
            assert_eq!(f.peers.len(), 1);
            assert_eq!(f.peers[0].name, "laptop");
            assert_eq!(f.peers[0].syncstate.as_deref(), Some("syncing"));
        }
    }

    #[test]
    fn parses_folders_with_missing_fields() {
        let v = json!({ "folders": [{ "path": "/only/path" }] });
        let folders = parse_folders(&v);
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].path, "/only/path");
        assert_eq!(folders[0].id, "");
        assert!(folders[0].peers.is_empty());
        // junk entries are dropped, not fatal
        let v2 = json!({ "folders": [42, "nope"] });
        assert!(parse_folders(&v2).is_empty());
    }

    #[test]
    fn parses_status_across_number_shapes() {
        let v = json!({ "speed_up": 1024, "speed_down": 2048.5, "paused": false, "uptime": 99, "version": "2.7.3" });
        let s = parse_status(&v);
        assert_eq!(s.speed_up, 1024.0);
        assert_eq!(s.speed_down, 2048.5);
        assert_eq!(s.version.as_deref(), Some("2.7.3"));
        let empty = json!({});
        let s2 = parse_status(&empty);
        assert_eq!(s2.speed_up, 0.0);
        assert!(!s2.paused);
    }

    #[test]
    fn parses_known_peers_array_and_wrapped() {
        let a = json!({ "peers": [{ "id": "x", "name": "n1" }] });
        let b = json!({ "data": { "peers": [{ "id": "x", "name": "n1" }] } });
        for v in [a, b] {
            assert_eq!(parse_known_peers(&v).len(), 1);
        }
    }

    #[test]
    fn parses_secrets_variants() {
        let v = json!({ "secret": "RWKEY", "rosecret": "ROKEY" });
        let s = parse_secrets(&v).unwrap();
        assert_eq!(s.secret, "RWKEY");
        assert_eq!(s.read_only.as_deref(), Some("ROKEY"));
        assert!(parse_secrets(&json!({ "nope": 1 })).is_none());
    }

    // ---- end-to-end against a tiny loopback HTTP mock ----

    fn spawn_mock(routes: Vec<(&'static str, u16, String)>) -> u16 {
        use std::io::{Read, Write};
        use std::net::TcpListener;
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
                let route = req
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split(' ')
                    .nth(1)
                    .unwrap_or("")
                    .split('?')
                    .next()
                    .unwrap_or("")
                    .to_string();
                let (code, body) = routes
                    .iter()
                    .find(|(p, _, _)| *p == route)
                    .map(|(_, c, b)| (*c, b.clone()))
                    .unwrap_or((404, "{\"error\":\"not found\"}".to_string()));
                let resp = format!(
                    "HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes());
                // Connection: close — drop after one response.
            }
        });
        port
    }

    #[tokio::test]
    async fn end_to_end_login_status_folders_add() {
        let port = spawn_mock(vec![
            ("/api/v2/auth/login", 200, "ok".into()),
            (
                "/api/v2/status",
                200,
                json!({ "speed_up": 10, "speed_down": 20, "paused": false }).to_string(),
            ),
            (
                "/api/v2/folders",
                200,
                json!({ "folders": [{ "id": "f1", "path": "/tmp/x", "secret": "S1" }] })
                    .to_string(),
            ),
            ("/api/v2/folders/add_folder", 200, "{}".into()),
            ("/api/v2/command", 200, "{}".into()),
        ]);
        let c = ResilioClient::new(port, "testkey", "u", "p");
        assert!(c.ping().await, "mock must answer on its port");
        c.login().await.expect("login succeeds");
        let st = c.status().await.expect("status");
        assert_eq!(st.speed_down, 20.0);
        let folders = c.folders().await.expect("folders");
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].id, "f1");
        c.add_folder("/tmp/new", Some("SECRET")).await.expect("add");
        c.pause_all(true).await.expect("pause");
        c.pause_all(false).await.expect("resume");
    }
}
