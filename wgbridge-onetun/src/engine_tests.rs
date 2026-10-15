//! Deterministic TCP lifecycle regressions below the WireGuard packet boundary.
use super::*;
use smoltcp::{
    phy::ChecksumCapabilities,
    wire::{IpProtocol, Ipv4Repr, TcpControl, TcpPacket, TcpRepr, TcpSeqNumber},
};
use tokio::io::AsyncReadExt;

async fn server(local_port: u16) -> Engine {
    let secret: [u8; 32] = rand::random();
    let peer = PublicKey::from(&StaticSecret::from(rand::random::<[u8; 32]>()));
    let config = BridgeConfig::parse(
        &serde_json::json!({
            "PrivateKey":base64::encode(secret), "Address":["10.99.0.2/32"],
            "Peers":[{"PublicKey":base64::encode(peer.as_bytes()), "AllowedIPs":["10.99.0.1/32"]}]
        })
        .to_string(),
    )
    .unwrap();
    Engine::new(
        config,
        vec![ServiceRoute {
            port: 6000,
            local_port,
            local_host: None,
        }],
    )
    .await
    .unwrap()
}
fn inject(
    engine: &mut Engine,
    port: u16,
    sequence: i32,
    ack: Option<TcpSeqNumber>,
    control: TcpControl,
    data: &[u8],
) {
    let source: IpAddress = "10.99.0.1".parse().unwrap();
    let dest: IpAddress = "10.99.0.2".parse().unwrap();
    let tcp = TcpRepr {
        src_port: port,
        dst_port: 6000,
        control,
        seq_number: TcpSeqNumber(sequence),
        ack_number: ack,
        window_len: 32768,
        window_scale: None,
        max_seg_size: None,
        sack_permitted: false,
        sack_ranges: [None; 3],
        timestamp: None,
        payload: data,
    };
    let ip = Ipv4Repr {
        src_addr: "10.99.0.1".parse().unwrap(),
        dst_addr: "10.99.0.2".parse().unwrap(),
        next_header: IpProtocol::Tcp,
        payload_len: tcp.header_len() + data.len(),
        hop_limit: 64,
    };
    let mut bytes = vec![0; ip.buffer_len() + ip.payload_len];
    let caps = ChecksumCapabilities::default();
    ip.emit(&mut Ipv4Packet::new_unchecked(&mut bytes[..]), &caps);
    tcp.emit(
        &mut TcpPacket::new_unchecked(&mut bytes[ip.buffer_len()..]),
        &source,
        &dest,
        &caps,
    );
    engine.device.receive_packet(&bytes);
    engine
        .interface
        .poll(engine.now(), &mut engine.device, &mut engine.sockets);
}
fn last_sequence(engine: &mut Engine) -> TcpSeqNumber {
    let packet = engine.device.outgoing.pop_back().unwrap();
    engine.device.outgoing.clear();
    let ip = Ipv4Packet::new_checked(&packet).unwrap();
    TcpPacket::new_checked(ip.payload()).unwrap().seq_number()
}

#[test]
fn incomplete_handshakes_expire_without_opening_native_connections() {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let mut engine = server(listener.local_addr().unwrap().port()).await;
            for port in 20000..20000 + MAX_CONNECTIONS as u16 {
                inject(&mut engine, port, 100, None, TcpControl::Syn, &[]);
                engine.accept_connections();
                engine.transfer_connections().await;
                engine.device.outgoing.clear();
            }
            assert_eq!(engine.connections.len(), MAX_CONNECTIONS);
            assert!(engine
                .connections
                .values()
                .all(|c| matches!(c, LocalConnection::Handshaking { .. })));
            assert!(
                tokio::time::timeout(Duration::from_millis(30), listener.accept())
                    .await
                    .is_err()
            );
            for connection in engine.connections.values_mut() {
                if let LocalConnection::Handshaking { deadline, .. } = connection {
                    *deadline = Clock::now();
                }
            }
            engine.step().await;
            assert!(engine.connections.is_empty(), "SYN slots must be reclaimed");
            inject(&mut engine, 23000, 100, None, TcpControl::Syn, &[]);
            engine.accept_connections();
            assert_eq!(
                engine.connections.len(),
                1,
                "listener must accept after expiration"
            );
        });
}

#[test]
fn closed_tcp_keeps_acknowledged_tail_until_native_backpressure_clears() {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            socket2::SockRef::from(&listener)
                .set_recv_buffer_size(4096)
                .unwrap();
            let stream = TcpStream::connect(listener.local_addr().unwrap())
                .await
                .unwrap();
            socket2::SockRef::from(&stream)
                .set_send_buffer_size(4096)
                .unwrap();
            let (mut receiver, _) = listener.accept().await.unwrap();
            let mut padding = 0;
            loop {
                match stream.try_write(&[9; 4096]) {
                    Ok(n) => {
                        padding += n;
                        assert!(padding < 4 * 1024 * 1024);
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => panic!("{e}"),
                }
            }
            let mut engine = server(listener.local_addr().unwrap().port()).await;
            inject(&mut engine, 24000, 100, None, TcpControl::Syn, &[]);
            let sequence = last_sequence(&mut engine);
            engine.accept_connections();
            let handle = *engine.connections.keys().next().unwrap();
            let payload = b"acknowledged-tail-must-survive";
            inject(
                &mut engine,
                24000,
                101,
                Some(sequence + 1),
                TcpControl::Fin,
                payload,
            );
            assert_eq!(
                engine.sockets.get::<tcp::Socket>(handle).state(),
                tcp::State::CloseWait
            );
            engine.sockets.get_mut::<tcp::Socket>(handle).close();
            engine
                .interface
                .poll(engine.now(), &mut engine.device, &mut engine.sockets);
            let fin_sequence = last_sequence(&mut engine);
            inject(
                &mut engine,
                24000,
                102 + payload.len() as i32,
                Some(fin_sequence + 1),
                TcpControl::None,
                &[],
            );
            let socket = engine.sockets.get::<tcp::Socket>(handle);
            assert_eq!(socket.state(), tcp::State::Closed);
            assert_eq!(socket.recv_queue(), payload.len());
            engine.connections.insert(
                handle,
                LocalConnection::Connected {
                    stream,
                    read_eof: true,
                    write_eof: false,
                },
            );
            engine.step().await;
            assert!(
                engine.connections.contains_key(&handle),
                "backpressured Closed socket was removed early"
            );
            let read = tokio::spawn(async move {
                let mut bytes = Vec::new();
                receiver.read_to_end(&mut bytes).await.unwrap();
                bytes
            });
            let deadline = Clock::now() + Duration::from_secs(3);
            while engine.connections.contains_key(&handle) {
                assert!(Clock::now() < deadline, "native backpressure never cleared");
                engine.step().await;
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            let bytes = tokio::time::timeout(Duration::from_secs(3), read)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(&bytes[..padding], vec![9; padding]);
            assert_eq!(&bytes[padding..], payload);
        });
}
