use crate::config::{cidr, key, BridgeConfig, ServiceRoute};
use crate::device::PacketDevice;
use anyhow::{anyhow, Context, Result};
use boringtun::{
    noise::{rate_limiter::RateLimiter, Tunn, TunnResult},
    x25519::{PublicKey, StaticSecret},
};
use smoltcp::{
    iface::{Config, Interface, SocketHandle, SocketSet},
    socket::tcp,
    time::Instant,
    wire::{HardwareAddress, IpAddress, IpCidr, Ipv4Packet, Ipv6Packet},
};
use socket2::{Domain, Protocol, SockAddr, Socket, Type};
use std::{
    collections::HashMap,
    io,
    net::{IpAddr, Shutdown, SocketAddr, UdpSocket},
    sync::{mpsc, Arc},
    time::{Duration, Instant as Clock},
};
use tokio::{net::TcpStream, task::JoinHandle};

const MAX_CONNECTIONS: usize = 128;
const BUFFER_SIZE: usize = 32 * 1024;
pub(crate) fn tcp_socket() -> tcp::Socket<'static> {
    let mut socket = tcp::Socket::new(
        tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
        tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
    );
    socket.set_nagle_enabled(false);
    socket
}
struct Peer {
    tunnel: Tunn,
    endpoint: Option<SocketAddr>,
    allowed: Vec<IpCidr>,
}
struct Listener {
    route: ServiceRoute,
    handle: SocketHandle,
}
enum LocalConnection {
    Handshaking {
        address: SocketAddr,
        deadline: Clock,
    },
    Connecting(JoinHandle<io::Result<TcpStream>>),
    Failed,
    Connected {
        stream: TcpStream,
        read_eof: bool,
        write_eof: bool,
    },
}
impl Drop for LocalConnection {
    fn drop(&mut self) {
        if let Self::Connecting(task) = self {
            task.abort();
        }
    }
}
enum Action {
    Network(Vec<u8>),
    Packet(Vec<u8>, IpAddr),
    Done,
    Invalid,
}
fn action(result: TunnResult<'_>) -> Action {
    match result {
        TunnResult::WriteToNetwork(bytes) => Action::Network(bytes.to_vec()),
        TunnResult::WriteToTunnelV4(bytes, src) => Action::Packet(bytes.to_vec(), src.into()),
        TunnResult::WriteToTunnelV6(bytes, src) => Action::Packet(bytes.to_vec(), src.into()),
        TunnResult::Done => Action::Done,
        TunnResult::Err(_) => Action::Invalid,
    }
}
pub(crate) struct Engine {
    udp: Vec<UdpSocket>,
    peers: Vec<Peer>,
    pub(crate) device: PacketDevice,
    pub(crate) interface: Interface,
    pub(crate) sockets: SocketSet<'static>,
    listeners: Vec<Listener>,
    connections: HashMap<SocketHandle, LocalConnection>,
    start: Clock,
    limiter: Arc<RateLimiter>,
}
impl Engine {
    pub async fn new(config: BridgeConfig, routes: Vec<ServiceRoute>) -> Result<Self> {
        config.validate()?;
        let mtu = config.mtu();
        let private = key(&config.private_key)?;
        let limiter = Arc::new(RateLimiter::new(
            &PublicKey::from(&StaticSecret::from(private)),
            100,
        ));
        let mut peers = Vec::new();
        for (index, peer) in config.peers.iter().enumerate() {
            let endpoint = match peer.endpoint.as_deref().filter(|v| !v.is_empty()) {
                Some(value) => Some(
                    tokio::time::timeout(Duration::from_secs(3), tokio::net::lookup_host(value))
                        .await
                        .map_err(|_| anyhow!("Peer endpoint resolution timed out"))?
                        .map_err(|_| anyhow!("Peer endpoint resolution failed"))?
                        .next()
                        .ok_or_else(|| anyhow!("Peer endpoint has no address"))?,
                ),
                None => None,
            };
            let psk = peer
                .preshared_key
                .as_deref()
                .filter(|s| !s.is_empty())
                .map(key)
                .transpose()?;
            let tunnel = Tunn::new(
                StaticSecret::from(private),
                PublicKey::from(key(&peer.public_key)?),
                psk,
                (peer.persistent_keepalive != 0).then_some(peer.persistent_keepalive),
                index as u32 + 1,
                Some(limiter.clone()),
            )
            .map_err(|_| anyhow!("Invalid WireGuard peer keys"))?;
            peers.push(Peer {
                tunnel,
                endpoint,
                allowed: peer
                    .allowed_ips
                    .iter()
                    .map(|s| cidr(s))
                    .collect::<Result<_>>()?,
            });
        }
        let v4 = UdpSocket::bind(("0.0.0.0", config.listen_port))
            .context("WireGuard UDP bind failed")?;
        v4.set_nonblocking(true)?;
        let port = v4.local_addr()?.port();
        let mut udp = vec![v4];
        let v6 = (|| -> io::Result<UdpSocket> {
            let socket = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
            socket.set_only_v6(true)?;
            socket.set_nonblocking(true)?;
            socket.bind(&SockAddr::from(SocketAddr::new(
                "::".parse().unwrap(),
                port,
            )))?;
            Ok(socket.into())
        })();
        match v6 {
            Ok(socket) => udp.push(socket),
            Err(error)
                if peers
                    .iter()
                    .any(|p| p.endpoint.is_some_and(|e| e.is_ipv6())) =>
            {
                return Err(error.into())
            }
            Err(_) => {}
        }
        let mut device = PacketDevice::new(mtu);
        let mut interface_config = Config::new(HardwareAddress::Ip);
        interface_config.random_seed = rand::random();
        let mut interface = Interface::new(interface_config, &mut device, Instant::from_millis(0));
        for address in &config.address {
            let address = cidr(address)?.address();
            let bits = if matches!(address, IpAddress::Ipv4(_)) {
                32
            } else {
                128
            };
            interface.update_ip_addrs(|addresses| {
                addresses.push(IpCidr::new(address, bits)).unwrap();
            });
            // IP medium needs a default route but performs no ARP/NDP resolution.
            match address {
                IpAddress::Ipv4(ip) => {
                    interface
                        .routes_mut()
                        .add_default_ipv4_route(ip)
                        .map_err(|_| anyhow!("Too many routes"))?;
                }
                IpAddress::Ipv6(ip) => {
                    interface
                        .routes_mut()
                        .add_default_ipv6_route(ip)
                        .map_err(|_| anyhow!("Too many routes"))?;
                }
            }
        }
        let mut engine = Self {
            udp,
            peers,
            device,
            interface,
            sockets: SocketSet::new(Vec::new()),
            listeners: vec![],
            connections: HashMap::new(),
            start: Clock::now(),
            limiter,
        };
        for route in routes {
            let handle = engine.listen(route.port)?;
            engine.listeners.push(Listener { route, handle });
        }
        Ok(engine)
    }
    #[cfg(test)]
    pub fn set_endpoint(&mut self, endpoint: SocketAddr) {
        self.peers[0].endpoint = Some(endpoint);
    }
    #[cfg(test)]
    pub fn handshake_complete(&self) -> bool {
        self.peers.iter().any(|p| p.tunnel.stats().0.is_some())
    }
    pub fn port(&self) -> u16 {
        self.udp[0].local_addr().unwrap().port()
    }
    fn listen(&mut self, port: u16) -> Result<SocketHandle> {
        let mut socket = tcp_socket();
        socket
            .listen(port)
            .map_err(|_| anyhow!("TCP service listen failed"))?;
        Ok(self.sockets.add(socket))
    }
    fn now(&self) -> Instant {
        Instant::from_millis(self.start.elapsed().as_millis() as i64)
    }
    fn peer_for(&self, ip: IpAddress) -> Option<usize> {
        self.peers
            .iter()
            .enumerate()
            .flat_map(|(i, peer)| {
                peer.allowed
                    .iter()
                    .filter(move |prefix| prefix.contains_addr(&ip))
                    .map(move |prefix| (prefix.prefix_len(), i))
            })
            .max()
            .map(|(_, i)| i)
    }
    fn send_udp(&self, bytes: &[u8], endpoint: SocketAddr) {
        let socket = self.udp.iter().find(|socket| {
            socket
                .local_addr()
                .is_ok_and(|addr| addr.is_ipv4() == endpoint.is_ipv4())
        });
        if let Some(socket) = socket {
            let _ = socket.send_to(bytes, endpoint);
        }
    }
    fn receive_udp(&mut self) {
        self.limiter.reset_count();
        let mut bytes = [0u8; 65536];
        let mut packets = Vec::new();
        for socket in &self.udp {
            for _ in 0..64 {
                match socket.recv_from(&mut bytes) {
                    Ok((len, source)) => packets.push((bytes[..len].to_vec(), source)),
                    Err(_) => break,
                }
            }
        }
        for (packet, source) in packets {
            let mut output = [0u8; 65568];
            for index in 0..self.peers.len() {
                let result = action(self.peers[index].tunnel.decapsulate(
                    Some(source.ip()),
                    &packet,
                    &mut output,
                ));
                if matches!(result, Action::Invalid) {
                    continue;
                }
                match result {
                    Action::Network(bytes) => {
                        // Cookie challenges are not authentication. Only an authenticated
                        // handshake response allows learning/roaming the remote endpoint.
                        if bytes.first() == Some(&2)
                            || (packet.first() == Some(&2) && bytes.first() == Some(&4))
                        {
                            self.peers[index].endpoint = Some(source);
                        }
                        self.send_udp(&bytes, source);
                    }
                    Action::Packet(bytes, ip) => {
                        if self.peer_for(ip.into()) == Some(index) {
                            self.peers[index].endpoint = Some(source);
                            self.device.receive_packet(&bytes);
                        }
                    }
                    Action::Done => {
                        // A successful handshake response or encrypted keepalive is
                        // authenticated; a cookie reply must not change the endpoint.
                        if matches!(packet.first(), Some(2 | 4)) {
                            self.peers[index].endpoint = Some(source);
                        }
                    }
                    Action::Invalid => unreachable!(),
                }
                // Flush packets BoringTun queued while the handshake was pending.
                for _ in 0..64 {
                    match action(self.peers[index].tunnel.decapsulate(None, &[], &mut output)) {
                        Action::Network(bytes) => {
                            if let Some(endpoint) = self.peers[index].endpoint {
                                self.send_udp(&bytes, endpoint);
                            }
                        }
                        _ => break,
                    }
                }
                break;
            }
        }
    }
    fn send_packets(&mut self) {
        let mut output = [0u8; 65568];
        while let Some(packet) = self.device.outgoing.pop_front() {
            let destination = match packet.first().map(|v| v >> 4) {
                Some(4) => Ipv4Packet::new_checked(&packet)
                    .ok()
                    .map(|p| IpAddress::Ipv4(p.dst_addr())),
                Some(6) => Ipv6Packet::new_checked(&packet)
                    .ok()
                    .map(|p| IpAddress::Ipv6(p.dst_addr())),
                _ => None,
            };
            if let Some(index) = destination.and_then(|ip| self.peer_for(ip)) {
                if let Action::Network(bytes) =
                    action(self.peers[index].tunnel.encapsulate(&packet, &mut output))
                {
                    if let Some(endpoint) = self.peers[index].endpoint {
                        self.send_udp(&bytes, endpoint);
                    }
                }
            }
        }
        for index in 0..self.peers.len() {
            if let Action::Network(bytes) =
                action(self.peers[index].tunnel.update_timers(&mut output))
            {
                if let Some(endpoint) = self.peers[index].endpoint {
                    self.send_udp(&bytes, endpoint);
                }
            }
        }
    }
    fn accept_connections(&mut self) {
        for index in 0..self.listeners.len() {
            let handle = self.listeners[index].handle;
            if !self.sockets.get::<tcp::Socket>(handle).is_active() {
                continue;
            }
            if self.connections.len() >= MAX_CONNECTIONS {
                let socket = self.sockets.get_mut::<tcp::Socket>(handle);
                socket.abort();
                // Keep the socket until the reset has been emitted in this step.
                continue;
            }
            let route = self.listeners[index].route.clone();
            let Ok(next) = self.listen(route.port) else {
                continue;
            };
            self.listeners[index].handle = next;
            let address = route.local_addr().unwrap();
            self.connections.insert(
                handle,
                LocalConnection::Handshaking {
                    address,
                    deadline: Clock::now() + Duration::from_secs(3),
                },
            );
        }
    }
    async fn transfer_connections(&mut self) {
        for (&handle, connection) in &mut self.connections {
            if let LocalConnection::Handshaking { address, deadline } = connection {
                let socket = self.sockets.get_mut::<tcp::Socket>(handle);
                if matches!(
                    socket.state(),
                    tcp::State::Established | tcp::State::CloseWait
                ) {
                    let address = *address;
                    *connection = LocalConnection::Connecting(tokio::spawn(async move {
                        match tokio::time::timeout(
                            Duration::from_secs(3),
                            TcpStream::connect(address),
                        )
                        .await
                        {
                            Ok(result) => result.and_then(|stream| {
                                stream.set_nodelay(true)?;
                                Ok(stream)
                            }),
                            Err(_) => Err(io::Error::new(
                                io::ErrorKind::TimedOut,
                                "Local service connect timed out",
                            )),
                        }
                    }));
                } else if Clock::now() >= *deadline || socket.state() == tcp::State::Closed {
                    socket.abort();
                    *connection = LocalConnection::Failed;
                } else {
                    continue;
                }
            }
            if let LocalConnection::Connecting(task) = connection {
                if !task.is_finished() {
                    continue;
                }
                let result = (&mut *task).await;
                match result {
                    Ok(Ok(stream)) => {
                        *connection = LocalConnection::Connected {
                            stream,
                            read_eof: false,
                            write_eof: false,
                        }
                    }
                    _ => {
                        self.sockets.get_mut::<tcp::Socket>(handle).abort();
                        *connection = LocalConnection::Failed;
                        continue;
                    }
                }
            }
            let LocalConnection::Connected {
                stream,
                read_eof,
                write_eof,
            } = connection
            else {
                continue;
            };
            let socket = self.sockets.get_mut::<tcp::Socket>(handle);
            // Closed may still contain data ACKed to the peer. Drain it before
            // closing the native write half, even after the FIN exchange ends.
            let mut failed = false;
            if socket.can_recv() {
                let _ = socket.recv(|bytes| match stream.try_write(bytes) {
                    Ok(len) => (len, ()),
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => (0, ()),
                    Err(_) => {
                        failed = true;
                        (0, ())
                    }
                });
            }
            if !*write_eof && !socket.may_recv() && socket.state() != tcp::State::SynReceived {
                if socket2::SockRef::from(&*stream)
                    .shutdown(Shutdown::Write)
                    .is_err()
                {
                    failed = true;
                }
                *write_eof = true;
            }
            if !*read_eof && socket.can_send() {
                let mut bytes = [0u8; 8192];
                let available = bytes
                    .len()
                    .min(socket.send_capacity() - socket.send_queue());
                match stream.try_read(&mut bytes[..available]) {
                    Ok(0) => {
                        *read_eof = true;
                        socket.close();
                    }
                    Ok(len) => {
                        let _ = socket.send_slice(&bytes[..len]);
                    }
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                    Err(_) => failed = true,
                }
            }
            if failed {
                socket.abort();
                *connection = LocalConnection::Failed;
            }
        }
    }
    pub async fn step(&mut self) {
        self.receive_udp();
        self.interface
            .poll(self.now(), &mut self.device, &mut self.sockets);
        self.accept_connections();
        self.transfer_connections().await;
        self.interface
            .poll(self.now(), &mut self.device, &mut self.sockets);
        self.send_packets();
        let closed = self
            .connections
            .iter()
            .filter_map(|(&h, connection)| {
                let socket = self.sockets.get::<tcp::Socket>(h);
                (socket.state() == tcp::State::Closed
                    && (matches!(connection, LocalConnection::Failed) || socket.recv_queue() == 0))
                    .then_some(h)
            })
            .collect::<Vec<_>>();
        for handle in closed {
            self.connections.remove(&handle);
            self.sockets.remove(handle);
        }
        // Rearm rejected listeners after their reset packet has been dispatched.
        for listener in &self.listeners {
            let socket = self.sockets.get_mut::<tcp::Socket>(listener.handle);
            if socket.state() == tcp::State::Closed {
                let _ = socket.listen(listener.route.port);
            }
        }
    }
    pub async fn run(&mut self, stopping: mpsc::Receiver<()>) {
        while matches!(stopping.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            self.step().await;
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        self.connections.clear();
        for (_, socket) in self.sockets.iter_mut() {
            if let smoltcp::socket::Socket::Tcp(socket) = socket {
                socket.abort();
            }
        }
        // Send TCP resets before dropping the encrypted transport.
        let deadline = Clock::now() + Duration::from_millis(50);
        while Clock::now() < deadline {
            self.interface
                .poll(self.now(), &mut self.device, &mut self.sockets);
            self.send_packets();
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod regression_tests;
