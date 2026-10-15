use super::*;
use boringtun::x25519::{PublicKey, StaticSecret};
use engine::tcp_socket;
use serde_json::json;
use smoltcp::{iface::SocketHandle, socket::tcp};
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn pair() -> ([u8; 32], String) {
    let secret: [u8; 32] = rand::random();
    let public = PublicKey::from(&StaticSecret::from(secret));
    (secret, base64::encode(public.as_bytes()))
}
fn configuration(
    secret: &[u8; 32],
    public: &str,
    endpoint: Option<String>,
    own: &str,
    remote: &str,
    port: u16,
) -> BridgeConfig {
    BridgeConfig::parse(&json!({
        "Address":[format!("10.99.0.{own}/32"),format!("fd00:99::{own}/128")],
        "PrivateKey":base64::encode(secret), "ListenPort":port, "MTU":1420,
        "Peers":[{"PublicKey":public,"PresharedKey":base64::encode([7;32]),"Endpoint":endpoint,
            "AllowedIPs":[format!("10.99.0.{remote}/32"),format!("fd00:99::{remote}/128")],"PersistentKeepalive":1}]
    }).to_string()).unwrap()
}
async fn echo(address: &str, greeting: &'static [u8]) -> (u16, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind(address).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let task = tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let _ = socket.write_all(greeting).await;
                let (mut reader, mut writer) = socket.into_split();
                let _ = tokio::io::copy(&mut reader, &mut writer).await;
                let _ = writer.shutdown().await;
            });
        }
    });
    (port, task)
}
async fn tick(peer: &mut Engine) {
    peer.step().await;
    tokio::time::sleep(Duration::from_millis(2)).await;
}
fn dial(peer: &mut Engine, address: &str, port: u16, source_port: u16) -> SocketHandle {
    let mut socket = tcp_socket();
    socket
        .connect(
            peer.interface.context(),
            (address.parse::<smoltcp::wire::IpAddress>().unwrap(), port),
            source_port,
        )
        .unwrap();
    peer.sockets.add(socket)
}
async fn connected(peer: &mut Engine, handle: SocketHandle) {
    let deadline = Instant::now() + Duration::from_secs(8);
    while !peer.sockets.get::<tcp::Socket>(handle).may_send() {
        assert!(
            Instant::now() < deadline,
            "encrypted TCP connection never established"
        );
        tick(peer).await;
    }
}
async fn exchange(peer: &mut Engine, handle: SocketHandle, payload: &[u8], expected: &[u8]) {
    connected(peer, handle).await;
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut sent = 0;
    let mut received = Vec::new();
    while sent < payload.len() || received.len() < expected.len() {
        assert!(
            Instant::now() < deadline,
            "TCP transfer timed out: sent={sent}, received={}",
            received.len()
        );
        let socket = peer.sockets.get_mut::<tcp::Socket>(handle);
        if socket.can_send() {
            sent += socket.send_slice(&payload[sent..]).unwrap();
        }
        while socket.can_recv() {
            let mut bytes = [0; 8192];
            let len = socket.recv_slice(&mut bytes).unwrap();
            received.extend_from_slice(&bytes[..len]);
        }
        tick(peer).await;
    }
    assert_eq!(
        received, expected,
        "service responses crossed or bytes were lost"
    );
}

#[test]
fn encrypted_dual_service_forwarding_and_stop_restart() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let (port_a, echo_a) = echo("[::1]:0", b"").await;
        let (port_b, echo_b) = echo("127.0.0.1:0", b"HTTP2:").await;
        let (server_secret, server_public) = pair();
        let (client_secret, client_public) = pair();
        let mut peer = Engine::new(
            configuration(&client_secret, &server_public, None, "1", "2", 0),
            vec![],
        )
        .await
        .unwrap();
        let config = || {
            configuration(
                &server_secret,
                &client_public,
                Some(format!("127.0.0.1:{}", peer.port())),
                "2",
                "1",
                0,
            )
        };
        let routes = vec![
            ServiceRoute {
                port: 5901,
                local_port: port_a,
                local_host: Some("::1".into()),
            },
            ServiceRoute {
                port: 6000,
                local_port: port_b,
                local_host: None,
            },
        ];
        let mut server_config = config();
        // A different peer precedes the actual client to exercise peer dispatch.
        let (_, unrelated_public) = pair();
        server_config.peers.insert(
            0,
            config::PeerConfig {
                public_key: unrelated_public,
                allowed_ips: vec!["10.88.0.1/32".into()],
                ..Default::default()
            },
        );
        let bridge = Bridge::start(server_config, routes.clone()).unwrap();
        let listen_port = bridge.port;
        peer.set_endpoint(format!("127.0.0.1:{listen_port}").parse().unwrap());
        let vnc = dial(&mut peer, "10.99.0.2", 5901, 20001);
        let http = dial(&mut peer, "fd00:99::2", 6000, 20002);
        exchange(&mut peer, vnc, b"VNC\0\r\n", b"VNC\0\r\n").await;
        exchange(
            &mut peer,
            http,
            b"POST /api/karing/version",
            b"HTTP2:POST /api/karing/version",
        )
        .await;
        assert!(
            peer.handshake_complete(),
            "must perform a real WireGuard handshake"
        );
        // Exercise sustained transfer beyond the bounded TCP buffers.
        let bulk = (0..256 * 1024).map(|i| (i % 251) as u8).collect::<Vec<_>>();
        exchange(&mut peer, vnc, &bulk, &bulk).await;
        drop(bridge);
        let deadline = Instant::now() + Duration::from_secs(1);
        while peer.sockets.get::<tcp::Socket>(vnc).is_open()
            || peer.sockets.get::<tcp::Socket>(http).is_open()
        {
            assert!(
                Instant::now() < deadline,
                "Stop left existing encrypted connections open"
            );
            tick(&mut peer).await;
        }
        let mut restarted = configuration(
            &server_secret,
            &client_public,
            Some(format!("127.0.0.1:{}", peer.port())),
            "2",
            "1",
            listen_port,
        );
        // Preserve all keys and the client's existing tunnel across restart.
        restarted.peers[0].persistent_keepalive = 1;
        let bridge = Bridge::start(restarted, routes[1..].to_vec()).unwrap();
        let reopened = dial(&mut peer, "10.99.0.2", 6000, 20003);
        exchange(&mut peer, reopened, b"again", b"HTTP2:again").await;
        drop(bridge);
        echo_a.abort();
        echo_b.abort();
    });
}

#[test]
fn half_close_preserves_response_and_unavailable_service_resets() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let reply = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            socket.read_to_end(&mut request).await.unwrap();
            assert_eq!(request, b"request-before-fin");
            socket.write_all(b"response-after-fin").await.unwrap();
            socket.shutdown().await.unwrap();
        });
        let unavailable = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let unavailable_port = unavailable.local_addr().unwrap().port();
        drop(unavailable);
        let (server_secret, server_public) = pair();
        let (client_secret, client_public) = pair();
        let mut peer = Engine::new(
            configuration(&client_secret, &server_public, None, "1", "2", 0),
            vec![],
        )
        .await
        .unwrap();
        let bridge = Bridge::start(
            configuration(&server_secret, &client_public, None, "2", "1", 0),
            vec![
                ServiceRoute {
                    port: 6000,
                    local_port: port,
                    local_host: None,
                },
                ServiceRoute {
                    port: 6001,
                    local_port: unavailable_port,
                    local_host: None,
                },
            ],
        )
        .unwrap();
        peer.set_endpoint(format!("[::1]:{}", bridge.port).parse().unwrap());
        let handle = dial(&mut peer, "10.99.0.2", 6000, 21000);
        connected(&mut peer, handle).await;
        peer.sockets
            .get_mut::<tcp::Socket>(handle)
            .send_slice(b"request-before-fin")
            .unwrap();
        peer.sockets.get_mut::<tcp::Socket>(handle).close();
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut response = Vec::new();
        loop {
            tick(&mut peer).await;
            let socket = peer.sockets.get_mut::<tcp::Socket>(handle);
            while socket.can_recv() {
                let mut bytes = [0; 1024];
                let count = socket.recv_slice(&mut bytes).unwrap();
                response.extend_from_slice(&bytes[..count]);
            }
            if !socket.may_recv() {
                break;
            }
            assert!(Instant::now() < deadline, "half-close never completed");
        }
        assert_eq!(response, b"response-after-fin");
        reply.await.unwrap();
        let refused = dial(&mut peer, "10.99.0.2", 6001, 21001);
        let deadline = Instant::now() + Duration::from_secs(3);
        while peer.sockets.get::<tcp::Socket>(refused).is_open() {
            assert!(
                Instant::now() < deadline,
                "unavailable local service did not reset connection"
            );
            tick(&mut peer).await;
        }
        drop(bridge);
    });
}

#[test]
fn authenticated_peer_cannot_spoof_source_outside_allowed_ips() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (server_secret, server_public) = pair();
        let (client_secret, client_public) = pair();
        let mut peer = Engine::new(
            configuration(&client_secret, &server_public, None, "3", "2", 0),
            vec![],
        )
        .await
        .unwrap();
        let bridge = Bridge::start(
            configuration(&server_secret, &client_public, None, "2", "1", 0),
            vec![ServiceRoute {
                port: 6000,
                local_port: listener.local_addr().unwrap().port(),
                local_host: None,
            }],
        )
        .unwrap();
        peer.set_endpoint(format!("127.0.0.1:{}", bridge.port).parse().unwrap());
        let handle = dial(&mut peer, "10.99.0.2", 6000, 22000);
        let deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < deadline {
            tick(&mut peer).await;
        }
        assert!(
            peer.handshake_complete(),
            "negative test must authenticate the peer first"
        );
        assert!(!peer.sockets.get::<tcp::Socket>(handle).may_send());
        assert!(
            tokio::time::timeout(Duration::from_millis(30), listener.accept())
                .await
                .is_err(),
            "disallowed source reached local service"
        );
        drop(bridge);
    });
}

#[test]
fn ffi_validates_inputs_without_a_caller_runtime_and_stop_is_idempotent() {
    unsafe {
        let error = TVNCWGStartServices(std::ptr::null(), std::ptr::null());
        assert!(!error.is_null());
        TVNCWGFree(error);
        TVNCWGFree(std::ptr::null_mut());
    }
    TVNCWGStop();
    TVNCWGStop();
    let (secret, _) = pair();
    let (_, public) = pair();
    let raw = CString::new(
        json!({"Address":["10.99.0.2/32"],"PrivateKey":base64::encode(secret),
        "Peers":[{"PublicKey":public,"AllowedIPs":["10.99.0.1/32"]}]})
        .to_string(),
    )
    .unwrap();
    let services = CString::new("[{\"Port\":5901,\"LocalPort\":5901}]").unwrap();
    unsafe {
        let error = TVNCWGStartServices(raw.as_ptr(), services.as_ptr());
        assert!(error.is_null());
        let duplicate = TVNCWGStartServices(raw.as_ptr(), services.as_ptr());
        assert!(!duplicate.is_null());
        TVNCWGFree(duplicate);
        TVNCWGStop();
        for port in [0, -1, 65536] {
            let error = TVNCWGStart(raw.as_ptr(), port);
            assert!(!error.is_null());
            TVNCWGFree(error);
        }
        assert!(TVNCWGStart(raw.as_ptr(), 5901).is_null());
        TVNCWGStop();
    }
}

#[test]
fn invalid_routes_keys_and_addresses_are_rejected_without_leaking_input() {
    for raw in [
        "[]",
        "[{\"Port\":0,\"LocalPort\":1}]",
        "[{\"Port\":1,\"LocalPort\":0}]",
        "[{\"Port\":1,\"LocalPort\":65536}]",
        "[{\"Port\":1,\"LocalPort\":1,\"LocalHost\":\"192.168.1.1\"}]",
        "[{\"Port\":1,\"LocalPort\":1},{\"Port\":1,\"LocalPort\":2}]",
    ] {
        assert!(config::parse_routes(raw)
            .and_then(|r| config::validate_routes(&r))
            .is_err());
    }
    let (secret, _) = pair();
    let (_, public) = pair();
    let mut config = configuration(&secret, &public, None, "2", "1", 0);
    config.private_key = "private-key-sentinel".into();
    let error = config.validate().unwrap_err().to_string();
    assert!(!error.contains("private-key-sentinel"));
    config.private_key = base64::encode(secret);
    config.peers[0].preshared_key = Some(base64::encode([1; 31]));
    assert!(config.validate().is_err());
    config.peers[0].preshared_key = None;
    config.peers.clear();
    assert!(config.validate().is_err());
}
