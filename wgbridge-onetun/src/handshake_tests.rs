//! Real encrypted UDP startup/recovery tests, with only the monotonic clock replaced.
use super::*;
use mock_instant::MockClock;
fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
}
async fn engine(sink: &UdpSocket) -> Engine {
    let private = [1u8; 32];
    let public = PublicKey::from(&StaticSecret::from([2u8; 32]));
    let config = BridgeConfig::parse(
        &serde_json::json!({
            "PrivateKey":base64::encode(private),"Address":["10.8.0.7/32"],
            "Peers":[{"PublicKey":base64::encode(public.as_bytes()),"AllowedIPs":["10.8.0.0/24"],
                "Endpoint":sink.local_addr().unwrap().to_string(),"PersistentKeepalive":120}]
        })
        .to_string(),
    )
    .unwrap();
    Engine::new(
        config,
        vec![ServiceRoute {
            port: 6000,
            local_port: 6000,
            local_host: None,
        }],
    )
    .await
    .unwrap()
}
fn drain(sink: &UdpSocket) -> usize {
    let mut count = 0;
    let mut buf = [0; 2048];
    while let Ok(n) = sink.recv(&mut buf) {
        assert_eq!(n, 148);
        assert_eq!(buf[0], 1);
        count += 1;
    }
    count
}
fn sink() -> UdpSocket {
    let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
    socket
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    socket
}
#[test]
fn configured_endpoint_initiates_without_waiting_for_120_second_keepalive() {
    runtime().block_on(async {
        MockClock::set_time(Duration::ZERO);
        let sink = sink();
        let engine = engine(&sink).await;
        assert_eq!(
            engine.connected_peers(),
            0,
            "an outgoing initiation is not a completed handshake"
        );
        assert_eq!(
            drain(&sink),
            1,
            "startup must initiate immediately, before any incoming traffic"
        );
    });
}
#[test]
fn expired_attempts_recover_and_complete_when_peer_returns() {
    runtime().block_on(async {
        MockClock::set_time(Duration::ZERO);
        let sink = sink();
        let mut engine = engine(&sink).await;
        let mut output = [0; 65568];
        // Start a known attempt even on the pre-fix engine, then simulate no replies.
        let _ = engine.peers[0]
            .tunnel
            .format_handshake_initiation(&mut output, false);
        drain(&sink);
        MockClock::advance(Duration::from_secs(91));
        engine.step().await;
        assert_eq!(
            drain(&sink),
            1,
            "an expired retry cycle must start a new attempt"
        );
        // Drop another full cycle, like a phone staying offline through VPN/network changes.
        MockClock::advance(Duration::from_secs(91));
        engine.step().await;
        let mut packet = [0; 2048];
        let (size, address) = sink
            .recv_from(&mut packet)
            .expect("second cycle did not recover");
        let mut peer = Tunn::new(
            StaticSecret::from([2u8; 32]),
            PublicKey::from(&StaticSecret::from([1u8; 32])),
            None,
            None,
            2,
            None,
        )
        .unwrap();
        let result = peer.decapsulate(Some(address.ip()), &packet[..size], &mut output);
        if let TunnResult::WriteToNetwork(bytes) = result {
            sink.send_to(bytes, address).unwrap();
        } else {
            panic!("recovered initiation was not valid");
        }
        for _ in 0..20 {
            engine.step().await;
            if engine.handshake_complete() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert!(
            engine.handshake_complete(),
            "recovery must complete a real authenticated handshake"
        );
        assert_eq!(engine.connected_peers(), 1);
        MockClock::advance(Duration::from_secs(181));
        assert_eq!(
            engine.connected_peers(),
            0,
            "an old handshake must not remain connected"
        );
        engine.step().await;
        assert_eq!(engine.connected_peers(), 0);
    });
}
