//! Userspace WireGuard service bridge. No system TUN device or route changes.
mod config;
mod device;
mod engine;

use anyhow::{anyhow, Result};
use config::{BridgeConfig, ServiceRoute};
use engine::Engine;
use std::ffi::{c_char, CStr, CString};
use std::sync::{mpsc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::Duration;

struct Bridge {
    stop: mpsc::Sender<()>,
    worker: Option<JoinHandle<()>>,
    #[cfg(test)]
    port: u16,
}
impl Bridge {
    fn start(config: BridgeConfig, services: Vec<ServiceRoute>) -> Result<Self> {
        config.validate()?;
        config::validate_routes(&services)?;
        let (stop, stopping) = mpsc::channel();
        let (ready, startup) = mpsc::sync_channel(1);
        let worker = std::thread::Builder::new()
            .name("tvnc-wireguard".into())
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(runtime) => runtime,
                    Err(_) => {
                        let _ = ready.send(Err(anyhow!("WireGuard runtime initialization failed")));
                        return;
                    }
                };
                runtime.block_on(async {
                    match tokio::time::timeout(
                        Duration::from_secs(5),
                        Engine::new(config, services),
                    )
                    .await
                    {
                        Ok(Ok(mut engine)) => {
                            if ready.send(Ok(engine.port())).is_ok() {
                                engine.run(stopping).await;
                            }
                        }
                        Ok(Err(error)) => {
                            let _ = ready.send(Err(error));
                        }
                        Err(_) => {
                            let _ = ready.send(Err(anyhow!("WireGuard startup timed out")));
                        }
                    }
                });
                runtime.shutdown_timeout(Duration::from_millis(100));
            })?;
        match startup.recv() {
            Ok(Ok(port)) => {
                #[cfg(not(test))]
                let _ = port;
                Ok(Self {
                    stop,
                    worker: Some(worker),
                    #[cfg(test)]
                    port,
                })
            }
            result => {
                let _ = stop.send(());
                let _ = worker.join();
                match result {
                    Ok(Err(error)) => Err(error),
                    _ => Err(anyhow!("WireGuard worker stopped during startup")),
                }
            }
        }
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

static ACTIVE: OnceLock<Mutex<Option<Bridge>>> = OnceLock::new();
fn active() -> &'static Mutex<Option<Bridge>> {
    ACTIVE.get_or_init(|| Mutex::new(None))
}
fn start(config: BridgeConfig, services: Vec<ServiceRoute>) -> Result<()> {
    let mut state = active()
        .lock()
        .map_err(|_| anyhow!("WireGuard state unavailable"))?;
    if state.is_some() {
        return Err(anyhow!("WireGuard is already started"));
    }
    *state = Some(Bridge::start(config, services)?);
    Ok(())
}
fn error_string(result: Result<()>) -> *mut c_char {
    match result {
        Ok(()) => std::ptr::null_mut(),
        Err(error) => CString::new(error.to_string().replace('\0', " "))
            .unwrap()
            .into_raw(),
    }
}
unsafe fn json_input<'a>(value: *const c_char) -> Result<&'a str> {
    if value.is_null() {
        return Err(anyhow!("JSON input is null"));
    }
    let bytes = unsafe { CStr::from_ptr(value) }.to_bytes();
    if bytes.len() > 256 * 1024 {
        return Err(anyhow!("JSON input exceeds 256 KiB"));
    }
    std::str::from_utf8(bytes).map_err(|_| anyhow!("JSON input is not UTF-8"))
}

/// Start only after the UDP sockets and service listeners are ready.
/// # Safety
/// Non-null arguments must point to readable, NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn TVNCWGStartServices(
    config_json: *const c_char,
    services_json: *const c_char,
) -> *mut c_char {
    error_string((|| {
        let config = BridgeConfig::parse(unsafe { json_input(config_json)? })?;
        let services = config::parse_routes(unsafe { json_input(services_json)? })?;
        start(config, services)
    })())
}
/// Single-service compatibility entry point.
/// # Safety
/// A non-null argument must point to a readable, NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn TVNCWGStart(config_json: *const c_char, port: i32) -> *mut c_char {
    error_string((|| {
        if !(1..=65535).contains(&port) {
            return Err(anyhow!("Invalid service port"));
        }
        let config = BridgeConfig::parse(unsafe { json_input(config_json)? })?;
        start(
            config,
            vec![ServiceRoute {
                port: port as u16,
                local_port: port as u16,
                local_host: None,
            }],
        )
    })())
}
#[no_mangle]
pub extern "C" fn TVNCWGStop() {
    if let Ok(mut state) = active().lock() {
        drop(state.take());
    }
}
/// # Safety
/// The pointer must be null or an unfreed error returned by a Start function.
#[no_mangle]
pub unsafe extern "C" fn TVNCWGFree(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests;
