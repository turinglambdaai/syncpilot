//! Owns the rslsync child process: spawn, adopt an already-running daemon,
//! supervise with crash backoff, and stop gracefully.

use crate::api::ResilioClient;
use crate::rslsync_config;
use crate::settings::AppSettings;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager as _};

#[derive(Debug, Clone, Serialize, PartialEq, Default)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    #[default]
    Stopped,
    Starting,
    Running,
    Crashed,
    Failed,
}

#[derive(Debug, Clone, Serialize)]
pub struct DaemonStatus {
    pub phase: Phase,
    pub pid: Option<u32>,
    pub uptime_secs: Option<u64>,
    pub binary: Option<String>,
    pub error: Option<String>,
    pub autostart: bool,
}

struct Inner {
    child: Option<Child>,
    phase: Phase,
    binary: Option<PathBuf>,
    started_at: Option<Instant>,
    manual_stop: bool,
    error: Option<String>,
}

pub struct Manager {
    app_dir: PathBuf,
    settings: Mutex<AppSettings>,
    inner: Mutex<Inner>,
}

impl Manager {
    pub fn new(app_dir: PathBuf, settings: AppSettings) -> Self {
        Self {
            app_dir,
            settings: Mutex::new(settings),
            inner: Mutex::new(Inner {
                child: None,
                phase: Phase::Stopped,
                binary: None,
                started_at: None,
                manual_stop: false,
                error: None,
            }),
        }
    }

    pub fn settings(&self) -> AppSettings {
        self.settings.lock().unwrap().clone()
    }

    pub fn update_settings(&self, s: AppSettings) {
        let mut g = self.settings.lock().unwrap();
        *g = s;
        g.persist(&self.app_dir);
    }

    pub fn status(&self) -> DaemonStatus {
        let g = self.inner.lock().unwrap();
        DaemonStatus {
            phase: g.phase.clone(),
            pid: g.child.as_ref().map(Child::id),
            uptime_secs: g.started_at.map(|t| t.elapsed().as_secs()),
            binary: g.binary.as_ref().map(|b| b.to_string_lossy().into_owned()),
            error: g.error.clone(),
            autostart: self.settings.lock().unwrap().autostart_daemon,
        }
    }

    pub fn client(&self) -> ResilioClient {
        let s = self.settings.lock().unwrap();
        ResilioClient::new(s.webui_port, &s.api_key, &s.webui_login, &s.webui_password)
    }

    /// Find the rslsync binary: explicit setting, well-known paths, then $PATH.
    pub fn find_binary(&self) -> Option<PathBuf> {
        let explicit = self.settings.lock().unwrap().rslsync_path.clone();
        let mut candidates: Vec<PathBuf> = Vec::new();
        if !explicit.trim().is_empty() {
            candidates.push(PathBuf::from(explicit.trim()));
        }
        candidates.push(PathBuf::from("/usr/bin/rslsync"));
        candidates.push(PathBuf::from("/usr/local/bin/rslsync"));
        candidates.push(PathBuf::from("/opt/resilio-sync/rslsync"));
        if let Some(path_env) = std::env::var_os("PATH") {
            for dir in std::env::split_paths(&path_env) {
                candidates.push(dir.join("rslsync"));
            }
        }
        candidates.into_iter().find(|p| is_executable_file(p))
    }

    /// Make sure a daemon answers on our port. Adopts one that is already
    /// running (e.g. started by systemd or kept from a previous session).
    pub async fn ensure_running(&self, app: &AppHandle) -> Result<(), String> {
        {
            let g = self.inner.lock().unwrap();
            if g.phase == Phase::Running {
                return Ok(());
            }
        }
        if self.client().ping().await {
            let mut g = self.inner.lock().unwrap();
            g.phase = Phase::Running;
            g.manual_stop = false;
            g.error = None;
            drop(g);
            let _ = app.emit("daemon://changed", self.status());
            return Ok(());
        }
        self.spawn_and_wait(app).await
    }

    async fn spawn_and_wait(&self, app: &AppHandle) -> Result<(), String> {
        let binary = self.find_binary().ok_or_else(|| {
            "rslsync binary not found. Install Resilio Sync or set its path in Settings."
                .to_string()
        })?;
        {
            let s = self.settings.lock().unwrap().clone();
            rslsync_config::write_conf(&self.app_dir, &s)
                .map_err(|e| format!("cannot write rslsync.conf: {e}"))?;
        }
        {
            let mut g = self.inner.lock().unwrap();
            g.phase = Phase::Starting;
            g.error = None;
            g.manual_stop = false;
        }
        let _ = app.emit("daemon://changed", self.status());

        let conf = rslsync_config::conf_path(&self.app_dir);
        let child = Command::new(&binary)
            .arg("--nodaemon")
            .arg("--config")
            .arg(&conf)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("failed to launch {}: {e}", binary.display()))?;
        {
            let mut g = self.inner.lock().unwrap();
            g.child = Some(child);
            g.binary = Some(binary);
            g.started_at = Some(Instant::now());
        }

        let client = self.client();
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            if client.ping().await {
                let mut g = self.inner.lock().unwrap();
                if let Some(c) = g.child.as_mut() {
                    let _ = c.try_wait();
                }
                g.phase = Phase::Running;
                drop(g);
                let _ = app.emit("daemon://changed", self.status());
                return Ok(());
            }
            let exited = {
                let mut g = self.inner.lock().unwrap();
                match g.child.as_mut() {
                    Some(c) => c.try_wait().map_or(true, |r| r.is_some()),
                    None => true,
                }
            };
            if exited {
                break;
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }

        let err = {
            let mut g = self.inner.lock().unwrap();
            let err = g
                .child
                .as_mut()
                .and_then(|c| c.try_wait().ok().flatten())
                .and_then(|st| st.code())
                .map(|c| format!("rslsync exited with code {c}"))
                .unwrap_or_else(|| "daemon did not answer within 30s".into());
            g.phase = Phase::Failed;
            g.error = Some(err.clone());
            err
        };
        let _ = app.emit("daemon://changed", self.status());
        Err(err)
    }

    /// Stop the daemon gracefully (API shutdown, then kill). With
    /// `keep_daemon_on_exit` the child is detached instead and left running.
    pub async fn stop(&self, app: &AppHandle) -> Result<(), String> {
        let keep = self.settings.lock().unwrap().keep_daemon_on_exit;
        {
            let mut g = self.inner.lock().unwrap();
            g.manual_stop = true;
        }
        if keep {
            let mut g = self.inner.lock().unwrap();
            g.child = None;
            g.phase = Phase::Stopped;
            g.started_at = None;
            drop(g);
            let _ = app.emit("daemon://changed", self.status());
            return Ok(());
        }
        let client = self.client();
        let _ = client.shutdown().await; // best effort
        for _ in 0..24 {
            {
                let mut g = self.inner.lock().unwrap();
                match g.child.as_mut() {
                    Some(c) => {
                        if matches!(c.try_wait(), Ok(Some(_))) {
                            g.child = None;
                            break;
                        }
                    }
                    None => break,
                }
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        {
            let mut g = self.inner.lock().unwrap();
            if let Some(mut c) = g.child.take() {
                let _ = c.kill();
                let _ = c.wait();
            }
            g.phase = Phase::Stopped;
            g.started_at = None;
        }
        let _ = app.emit("daemon://changed", self.status());
        Ok(())
    }
}

fn is_executable_file(p: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(p) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// Background watchdog: restart the daemon with backoff after a crash.
pub async fn supervisor(app: AppHandle) {
    let mut backoff_secs = 2u64;
    loop {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let m = app.state::<Manager>();
        let crash = {
            let mut g = m.inner.lock().unwrap();
            if g.phase == Phase::Running && !g.manual_stop {
                match g.child.as_mut() {
                    Some(c) => matches!(c.try_wait(), Ok(Some(_))),
                    None => false,
                }
            } else {
                false
            }
        };
        if !crash {
            continue;
        }
        let restart = m.settings.lock().unwrap().restart_on_crash;
        if restart {
            tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
            {
                // Reap the dead child and clear the phase so ensure_running
                // does not bail out on a stale Running state.
                let mut g = m.inner.lock().unwrap();
                if let Some(mut c) = g.child.take() {
                    let _ = c.wait();
                }
                g.phase = Phase::Stopped;
            }
            let _ = m.ensure_running(&app).await;
            backoff_secs = (backoff_secs * 2).min(60);
        } else {
            {
                let mut g = m.inner.lock().unwrap();
                g.phase = Phase::Crashed;
                g.error = Some("daemon exited unexpectedly".into());
            }
            let _ = app.emit("daemon://changed", m.status());
        }
    }
}
