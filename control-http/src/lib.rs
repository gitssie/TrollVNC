//! HTTP/2 (h2c prior knowledge) control listener and byte-preserving Karing proxy.
use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited, combinators::UnsyncBoxBody};
use hyper::{
    Request, Response, StatusCode,
    body::Incoming,
    header::{AUTHORIZATION, HOST, HeaderMap, HeaderValue},
    service::service_fn,
};
use hyper_util::rt::{TokioExecutor, TokioIo};
use std::{
    collections::HashSet,
    ffi::{CStr, c_char, c_void},
    net::TcpListener as StdListener,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    runtime::Runtime,
    sync::watch,
};
type Error = Box<dyn std::error::Error + Send + Sync>;
type Body = UnsyncBoxBody<Bytes, Error>;
const LIMIT: usize = 4 * 1024 * 1024;
#[repr(C)]
pub struct NativeResponse {
    pub data: *mut u8,
    pub len: usize,
    pub status: u16,
    pub content_type: *const c_char,
    pub stream: *mut c_void,
}

struct NativeStream(tokio::sync::mpsc::Receiver<Bytes>);
impl hyper::body::Body for NativeStream {
    type Data = Bytes;
    type Error = Error;
    fn poll_frame(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<hyper::body::Frame<Bytes>, Error>>> {
        self.0
            .poll_recv(cx)
            .map(|item| item.map(|bytes| Ok(hyper::body::Frame::data(bytes))))
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvnc_http_stream_new(producer: *mut *mut c_void) -> *mut c_void {
    let (sender, receiver) = tokio::sync::mpsc::channel::<Bytes>(16);
    unsafe {
        *producer = Box::into_raw(Box::new(sender)).cast();
    }
    Box::into_raw(Box::new(NativeStream(receiver))).cast()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvnc_http_stream_send(
    producer: *mut c_void,
    data: *const u8,
    len: usize,
) -> bool {
    let sender = unsafe { &*producer.cast::<tokio::sync::mpsc::Sender<Bytes>>() };
    // Bounded progress only; a slow/cancelled consumer stops native work.
    sender
        .try_send(Bytes::copy_from_slice(unsafe {
            std::slice::from_raw_parts(data, len)
        }))
        .is_ok()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvnc_http_stream_open(producer: *mut c_void) -> bool {
    !unsafe { &*producer.cast::<tokio::sync::mpsc::Sender<Bytes>>() }.is_closed()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvnc_http_stream_release(producer: *mut c_void) {
    drop(unsafe { Box::from_raw(producer.cast::<tokio::sync::mpsc::Sender<Bytes>>()) });
}

pub type Handler = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *const u8,
    usize,
    *const c_char,
    u64,
) -> NativeResponse;
pub type Disconnect = unsafe extern "C" fn(*mut c_void, u64);
pub type Release = unsafe extern "C" fn(*mut c_void);
struct Context {
    ptr: *mut c_void,
    handler: Handler,
    disconnect: Disconnect,
    release: Release,
}
// Objective-C facade synchronizes its native state and keeps UIKit work on main.
unsafe impl Send for Context {}
unsafe impl Sync for Context {}
impl Drop for Context {
    fn drop(&mut self) {
        unsafe { (self.release)(self.ptr) };
    }
}
struct State {
    context: Context,
    upstream: String,
    secret: String,
    clients: Mutex<HashSet<u64>>,
    next: AtomicU64,
}
pub struct Server {
    runtime: Option<Runtime>,
    stop: watch::Sender<bool>,
    state: Arc<State>,
}
fn full(status: u16, body: impl Into<Bytes>, content_type: &str) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("content-type", content_type)
        .body(
            Full::new(body.into())
                .map_err(|never| match never {})
                .boxed_unsync(),
        )
        .unwrap()
}
fn failure(status: u16, code: &str) -> Response<Body> {
    full(
        status,
        format!(r#"{{"error":{{"code":"{code}"}}}}"#),
        "application/json",
    )
}
async fn native(
    state: Arc<State>,
    path: String,
    bytes: Bytes,
    token: String,
    client: u64,
) -> Response<Body> {
    let result = tokio::task::spawn_blocking(move || {
        let path = std::ffi::CString::new(path).map_err(|_| ())?;
        let token = std::ffi::CString::new(token).map_err(|_| ())?;
        let reply = unsafe {
            (state.context.handler)(
                state.context.ptr,
                path.as_ptr(),
                bytes.as_ptr(),
                bytes.len(),
                token.as_ptr(),
                client,
            )
        };
        if !reply.stream.is_null() {
            let stream = unsafe { *Box::from_raw(reply.stream.cast::<NativeStream>()) };
            return Ok(Response::builder()
                .status(reply.status)
                .header("content-type", "application/x-ndjson")
                .header("cache-control", "no-store")
                .body(stream.boxed_unsync())
                .unwrap());
        }
        if reply.data.is_null() {
            return Err(());
        }
        let body =
            unsafe { Bytes::copy_from_slice(std::slice::from_raw_parts(reply.data, reply.len)) };
        unsafe {
            libc::free(reply.data.cast());
        }
        let content_type = if reply.content_type.is_null() {
            "application/json".to_string()
        } else {
            unsafe { CStr::from_ptr(reply.content_type) }
                .to_string_lossy()
                .into_owned()
        };
        Ok(full(reply.status, body, &content_type))
    })
    .await;
    result
        .ok()
        .and_then(Result::ok)
        .unwrap_or_else(|| failure(500, "native_failure"))
}
fn strip_hop(headers: &mut HeaderMap) {
    // RFC 9110: remove both fixed hop headers and Connection-nominated fields.
    let named: Vec<String> = headers
        .get_all("connection")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(',').map(|s| s.trim().to_string()))
        .collect();
    for name in named {
        headers.remove(name);
    }
    for name in [
        "connection",
        "keep-alive",
        "proxy-connection",
        "transfer-encoding",
        "upgrade",
        "te",
        "trailer",
    ] {
        headers.remove(name);
    }
}
async fn proxy(state: Arc<State>, mut request: Request<Incoming>) -> Result<Response<Body>, Error> {
    // Do not parse/re-serialize JSON, decode path components, follow redirects,
    // decompress, impose a stream deadline, or retry an upstream request.
    let raw = request
        .uri()
        .path_and_query()
        .ok_or("missing path")?
        .as_str();
    let target = raw.strip_prefix("/api/karing").ok_or("invalid route")?;
    if !target.starts_with('/') {
        return Ok(failure(404, "route_unavailable"));
    }
    let uri: hyper::Uri = target.parse()?;
    let socket =
        tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(&state.upstream)).await??;
    socket.set_nodelay(true)?;
    let (mut sender, connection) =
        hyper::client::conn::http1::handshake(TokioIo::new(socket)).await?;
    // The returned body owns the response stream; cancellation drops it and the
    // upstream connection. No detached producer or unbounded buffering.
    tokio::spawn(async move {
        let _ = connection.await;
    });
    *request.uri_mut() = uri;
    *request.version_mut() = hyper::Version::HTTP_11;
    strip_hop(request.headers_mut());
    request.headers_mut().remove(AUTHORIZATION);
    request.headers_mut().remove("proxy-authorization");
    request
        .headers_mut()
        .insert(HOST, HeaderValue::from_str(&state.upstream)?);
    if !state.secret.is_empty() {
        request.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {}", state.secret))?,
        );
    }
    let response = sender.send_request(request).await?;
    let (mut parts, body) = response.into_parts();
    strip_hop(&mut parts.headers);
    Ok(Response::from_parts(
        parts,
        body.map_err(|e| -> Error { Box::new(e) }).boxed_unsync(),
    ))
}
async fn route(
    state: Arc<State>,
    request: Request<Incoming>,
    client: u64,
) -> Result<Response<Body>, std::convert::Infallible> {
    let path = request.uri().path().to_owned();
    let token = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("")
        .to_string();
    // The password exchange is the only unauthenticated route. Its native
    // handler validates the existing VNC password before issuing a JWT.
    if path != "/api/control/connect" {
        let auth = native(
            state.clone(),
            "/api/control/authorize".into(),
            Bytes::new(),
            token.clone(),
            client,
        )
        .await;
        if auth.status() != StatusCode::OK {
            return Ok(auth);
        }
        if path == "/api/control/authorize" {
            return Ok(if request.method() == hyper::Method::POST {
                auth
            } else {
                failure(405, "method_not_allowed")
            });
        }
    }
    if path.starts_with("/api/karing/") {
        return Ok(proxy(state, request)
            .await
            .unwrap_or_else(|_| failure(502, "karing_transport_failure")));
    }
    if request.method() != hyper::Method::POST {
        return Ok(failure(405, "method_not_allowed"));
    }
    let body = match tokio::time::timeout(
        Duration::from_secs(10),
        Limited::new(request.into_body(), LIMIT).collect(),
    )
    .await
    {
        Ok(Ok(body)) => body.to_bytes(),
        _ => return Ok(failure(413, "invalid_request_body")),
    };
    Ok(native(state, path, body, token, client).await)
}
impl Server {
    fn start(
        listener: StdListener,
        upstream: String,
        secret: String,
        context: Context,
    ) -> std::io::Result<Self> {
        listener.set_nonblocking(true)?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()?;
        let state = Arc::new(State {
            context,
            upstream,
            secret,
            clients: Mutex::new(HashSet::new()),
            next: AtomicU64::new(1),
        });
        let (stop, mut stopped) = watch::channel(false);
        let shared = state.clone();
        let _guard = runtime.enter();
        let listener = TcpListener::from_std(listener)?;
        runtime.spawn(async move {
            loop {
                let accepted = tokio::select! { _ = stopped.changed() => break, result = listener.accept() => result };
                let Ok((socket, _)) = accepted else { break };
                let state = shared.clone();
                let id = state.next.fetch_add(1, Ordering::Relaxed);
                state.clients.lock().unwrap().insert(id);
                let mut stop = stopped.clone();
                tokio::spawn(async move {
                    let _ = socket.set_nodelay(true);
                    let service_state = state.clone();
                    let service = service_fn(move |request| route(service_state.clone(), request, id));
                    let builder = hyper::server::conn::http2::Builder::new(TokioExecutor::new());
                    let connection = builder.serve_connection(TokioIo::new(socket), service);
                    tokio::select! { _ = stop.changed() => {}, _ = connection => {} }
                    state.clients.lock().unwrap().remove(&id);
                    // Never block runtime I/O or main while releasing native touches.
                    tokio::task::spawn_blocking(move || unsafe { (state.context.disconnect)(state.context.ptr, id) });
                });
            }
        });
        drop(_guard);
        Ok(Self {
            runtime: Some(runtime),
            stop,
            state,
        })
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}
/// All strings are copied. Context ownership transfers even if binding fails.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvnc_http_start(
    host: *const c_char,
    port: u16,
    upstream: *const c_char,
    secret: *const c_char,
    ptr: *mut c_void,
    handler: Handler,
    disconnect: Disconnect,
    release: Release,
) -> *mut Server {
    let context = Context {
        ptr,
        handler,
        disconnect,
        release,
    };
    let host = unsafe { CStr::from_ptr(host) }.to_string_lossy();
    let upstream = unsafe { CStr::from_ptr(upstream) }
        .to_string_lossy()
        .into_owned();
    let secret = unsafe { CStr::from_ptr(secret) }
        .to_string_lossy()
        .into_owned();
    let result = StdListener::bind((host.as_ref(), port))
        .and_then(|listener| Server::start(listener, upstream, secret, context));
    result.map_or(std::ptr::null_mut(), |server| {
        Box::into_raw(Box::new(server))
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvnc_http_connected(server: *mut Server, client: u64) -> bool {
    !server.is_null()
        && unsafe { &*server }
            .state
            .clients
            .lock()
            .unwrap()
            .contains(&client)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvnc_http_stop(server: *mut Server) {
    if !server.is_null() {
        drop(unsafe { Box::from_raw(server) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    static NATIVE_CANCELLED: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);
    unsafe extern "C" fn handler(
        _: *mut c_void,
        path: *const c_char,
        data: *const u8,
        len: usize,
        token: *const c_char,
        _: u64,
    ) -> NativeResponse {
        let path = unsafe { CStr::from_ptr(path) }.to_str().unwrap();
        let token = unsafe { CStr::from_ptr(token) }.to_str().unwrap();
        if token == "control-token" && path == "/api/device/stream-fixture" {
            let mut producer = std::ptr::null_mut();
            let stream = unsafe { tvnc_http_stream_new(&mut producer) };
            let producer = producer as usize;
            std::thread::spawn(move || {
                let producer = producer as *mut c_void;
                unsafe {
                    assert!(tvnc_http_stream_send(
                        producer,
                        b"{\"phase\":\"preparing\"}\n".as_ptr(),
                        22
                    ));
                }
                for _ in 0..500 {
                    if !unsafe { tvnc_http_stream_open(producer) } {
                        NATIVE_CANCELLED.store(true, Ordering::SeqCst);
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                unsafe {
                    tvnc_http_stream_release(producer);
                }
            });
            return NativeResponse {
                data: std::ptr::null_mut(),
                len: 0,
                status: 200,
                content_type: c"application/x-ndjson".as_ptr(),
                stream,
            };
        }
        let (status, bytes) = if path == "/api/control/connect" {
            let value = unsafe { std::slice::from_raw_parts(data, len) };
            if value == br#"{"password":"fixture-password"}"# {
                (200, br#"{"access_token":"fixture-jwt","token_type":"Bearer"}"#.to_vec())
            } else { (401, br#"{"error":"authentication_failed"}"#.to_vec()) }
        } else if token != "control-token" {
            (401, br#"{"error":"unauthorized"}"#.to_vec())
        } else if path == "/api/control/authorize" {
            (200, br#"{"ok":true}"#.to_vec())
        } else {
            (
                200,
                unsafe { std::slice::from_raw_parts(data, len) }.to_vec(),
            )
        };
        let ptr = unsafe { libc::malloc(bytes.len().max(1)) }.cast::<u8>();
        unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len()) };
        NativeResponse {
            data: ptr,
            len: bytes.len(),
            status,
            stream: std::ptr::null_mut(),
            content_type: c"application/json".as_ptr(),
        }
    }
    unsafe extern "C" fn disconnected(_: *mut c_void, _: u64) {}
    unsafe extern "C" fn release(_: *mut c_void) {}
    fn start(upstream: String) -> (Server, String) {
        let listener = StdListener::bind("127.0.0.1:0").unwrap();
        let address = format!("http://{}", listener.local_addr().unwrap());
        let server = Server::start(
            listener,
            upstream,
            "karing-secret".into(),
            Context {
                ptr: std::ptr::null_mut(),
                handler,
                disconnect: disconnected,
                release,
            },
        )
        .unwrap();
        (server, address)
    }
    fn client() -> reqwest::Client {
        reqwest::Client::builder()
            .http2_prior_knowledge()
            .no_proxy()
            .retry(reqwest::retry::never())
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap()
    }
    #[tokio::test]
    async fn password_exchange_is_available_before_bearer_authorization() {
        let (_server, address) = start("127.0.0.1:1".into());
        let client = client();
        let login = client.post(format!("{address}/api/control/connect"))
            .body(r#"{"password":"fixture-password"}"#).send().await.unwrap();
        assert_eq!(login.status(), 200, "first login must not require a previously issued token");
        assert!(login.text().await.unwrap().contains("fixture-jwt"));
        assert_eq!(client.post(format!("{address}/api/control/connect")).body(r#"{"password":"wrong"}"#).send().await.unwrap().status(), 401);
        for path in ["/api/control/authorize", "/api/control/disconnect", "/api/control/connect/", "/api/apps/list", "/api/karing/version"] {
            assert_eq!(client.post(format!("{address}{path}")).body("{}").send().await.unwrap().status(), 401, "only exact login route may bypass token authorization");
        }
        assert_eq!(client.get(format!("{address}/api/control/connect")).send().await.unwrap().status(), 405);
    }
    #[tokio::test]
    async fn native_progress_stream_arrives_before_finish_and_cancels_on_drop() {
        NATIVE_CANCELLED.store(false, Ordering::SeqCst);
        let (_server, address) = start("127.0.0.1:1".into());
        let client = client();
        let mut response = client
            .post(format!("{address}/api/device/stream-fixture"))
            .bearer_auth("control-token")
            .body("{}")
            .send()
            .await
            .unwrap();
        assert_eq!(response.headers()["content-type"], "application/x-ndjson");
        let chunk = tokio::time::timeout(Duration::from_secs(1), response.chunk())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(chunk, b"{\"phase\":\"preparing\"}\n".as_slice());
        // A second stream on the same client completes while native progress waits.
        assert_eq!(
            client
                .post(format!("{address}/api/control/authorize"))
                .bearer_auth("control-token")
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
        drop(response);
        tokio::time::timeout(Duration::from_secs(2), async {
            while !NATIVE_CANCELLED.load(Ordering::SeqCst) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }
    #[test]
    fn native_stream_is_bounded_and_producer_outlives_dropped_receiver() {
        unsafe {
            let mut producer = std::ptr::null_mut();
            let receiver = tvnc_http_stream_new(&mut producer);
            for _ in 0..16 {
                assert!(tvnc_http_stream_send(producer, b"x".as_ptr(), 1));
            }
            assert!(!tvnc_http_stream_send(producer, b"x".as_ptr(), 1));
            drop(Box::from_raw(receiver.cast::<NativeStream>()));
            assert!(!tvnc_http_stream_open(producer));
            assert!(!tvnc_http_stream_send(producer, b"x".as_ptr(), 1));
            tvnc_http_stream_release(producer);
        }
    }
    async fn read_request(socket: &mut TcpStream) -> Vec<u8> {
        let mut bytes = Vec::new();
        let mut one = [0; 1];
        while !bytes.ends_with(b"\r\n\r\n") {
            socket.read_exact(&mut one).await.unwrap();
            bytes.push(one[0]);
        }
        let headers = String::from_utf8(bytes.clone()).unwrap();
        let length: usize = headers
            .lines()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length: ")
                    .map(|v| v.parse().unwrap())
            })
            .unwrap_or(0);
        let mut body = vec![0; length];
        socket.read_exact(&mut body).await.unwrap();
        bytes.extend(body);
        bytes
    }
    #[tokio::test]
    async fn raw_method_query_binary_status_headers_unknown_fields_and_redirects() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (server, origin) = start(upstream.local_addr().unwrap().to_string());
        let peer = tokio::spawn(async move {
            let (mut socket, _) = upstream.accept().await.unwrap();
            let raw = read_request(&mut socket).await;
            let text = String::from_utf8_lossy(&raw);
            assert!(text.starts_with("PATCH /configs?future=a%2Fb&future=x+y HTTP/1.1\r\n"));
            assert!(
                text.to_ascii_lowercase()
                    .contains("authorization: bearer karing-secret\r\n")
            );
            assert!(!text.contains("control-token"));
            assert!(raw.ends_with(br#"{"future":{"nested":[1,null,"a;;b\r\n"]}}"#));
            socket.write_all(b"HTTP/1.1 307 Temporary Redirect\r\nContent-Length: 8\r\nX-Future: raw\r\nLocation: /other\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n\0\xffa;;b\r\n").await.unwrap();
        });
        let response = client()
            .patch(format!(
                "{origin}/api/karing/configs?future=a%2Fb&future=x+y"
            ))
            .bearer_auth("control-token")
            .body(br#"{"future":{"nested":[1,null,"a;;b\r\n"]}}"#.to_vec())
            .send()
            .await
            .unwrap();
        assert_eq!(response.version(), reqwest::Version::HTTP_2);
        assert_eq!(response.status(), 307);
        assert_eq!(response.headers()["x-future"], "raw");
        assert_eq!(response.headers()["location"], "/other");
        assert!(!response.headers().contains_key("connection"));
        assert_eq!(response.bytes().await.unwrap().as_ref(), b"\0\xffa;;b\r\n");
        peer.await.unwrap();
        drop(server);
    }
    #[tokio::test]
    async fn continuous_stream_multiplexing_and_cancel_close_upstream() {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (server, origin) = start(upstream.local_addr().unwrap().to_string());
        let peer = tokio::spawn(async move {
            let (mut socket, _) = upstream.accept().await.unwrap();
            read_request(&mut socket).await;
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n{\"up\":1}\n\r\n").await.unwrap();
            let mut bytes = [0; 32];
            let result = tokio::time::timeout(Duration::from_secs(5), socket.read(&mut bytes))
                .await
                .unwrap();
            assert!(
                matches!(result, Ok(0) | Err(_)),
                "stream cancellation must close upstream"
            );
        });
        let client = client();
        let mut response = client
            .get(format!("{origin}/api/karing/traffic"))
            .bearer_auth("control-token")
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.chunk().await.unwrap().unwrap().as_ref(),
            b"{\"up\":1}\n"
        );
        let control = client
            .post(format!("{origin}/api/device/test"))
            .bearer_auth("control-token")
            .body("{\"future\":\"a;;b\"}")
            .send()
            .await
            .unwrap();
        assert_eq!(control.text().await.unwrap(), "{\"future\":\"a;;b\"}");
        drop(response);
        peer.await.unwrap();
        drop(server);
    }
    #[tokio::test]
    async fn karing_native_routes_use_authenticated_native_dispatch_not_proxy() {
        // Upstream is unreachable: success proves this namespace is native.
        let (server, origin) = start("127.0.0.1:1".into());
        let client = client();
        for operation in ["config", "profiles", "status", "reload"] {
            let url = format!("{origin}/api/karing-native/{operation}");
            assert_eq!(
                client.post(&url).body("{}").send().await.unwrap().status(),
                401
            );
            assert_eq!(
                client
                    .get(&url)
                    .bearer_auth("control-token")
                    .send()
                    .await
                    .unwrap()
                    .status(),
                405
            );
            let response = client
                .post(&url)
                .bearer_auth("control-token")
                .body("{}")
                .send()
                .await
                .unwrap();
            assert_eq!(response.version(), reqwest::Version::HTTP_2);
            assert_eq!(response.status(), 200);
            assert_eq!(response.text().await.unwrap(), "{}");
        }
        drop(server);
    }
    #[tokio::test]
    async fn authorization_upstream_failure_body_limit_and_shutdown() {
        let (server, origin) = start("127.0.0.1:1".into());
        let client = client();
        assert_eq!(
            client
                .get(format!("{origin}/api/karing/version"))
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        assert_eq!(
            client
                .get(format!("{origin}/api/karing/version"))
                .bearer_auth("control-token")
                .send()
                .await
                .unwrap()
                .status(),
            502
        );
        assert_eq!(
            client
                .post(format!("{origin}/api/device/test"))
                .bearer_auth("control-token")
                .body(vec![b'x'; LIMIT + 1])
                .send()
                .await
                .unwrap()
                .status(),
            413
        );
        drop(server);
        assert!(
            client
                .post(format!("{origin}/api/control/authorize"))
                .bearer_auth("control-token")
                .send()
                .await
                .is_err()
        );
    }
}
