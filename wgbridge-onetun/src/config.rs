use anyhow::{anyhow, Result};
use serde::Deserialize;
use smoltcp::wire::IpCidr;
use std::collections::HashSet;
use std::net::{IpAddr, SocketAddr};

// Never derive Debug for configuration containing private or preshared keys.
#[derive(Default, Deserialize)]
#[serde(default, rename_all = "PascalCase")]
pub(crate) struct PeerConfig {
    pub public_key: String,
    pub preshared_key: Option<String>,
    pub endpoint: Option<String>,
    #[serde(rename = "AllowedIPs")]
    pub allowed_ips: Vec<String>,
    pub persistent_keepalive: u16,
}
#[derive(Default, Deserialize)]
#[serde(default, rename_all = "PascalCase")]
pub(crate) struct BridgeConfig {
    pub address: Vec<String>,
    pub private_key: String,
    pub listen_port: u16,
    #[serde(rename = "MTU")]
    pub mtu: u16,
    pub peers: Vec<PeerConfig>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub(crate) struct ServiceRoute {
    pub port: u16,
    pub local_port: u16,
    pub local_host: Option<String>,
}
impl ServiceRoute {
    pub fn local_addr(&self) -> Result<SocketAddr> {
        let host: IpAddr = self
            .local_host
            .as_deref()
            .filter(|h| !h.is_empty())
            .unwrap_or("127.0.0.1")
            .parse()
            .map_err(|_| anyhow!("Service destination must be loopback"))?;
        if !host.is_loopback() {
            return Err(anyhow!("Service destination must be loopback"));
        }
        Ok(SocketAddr::new(host, self.local_port))
    }
}
pub(crate) fn key(value: &str) -> Result<[u8; 32]> {
    let bytes =
        base64::decode(value).map_err(|_| anyhow!("WireGuard key must be 32 bytes of base64"))?;
    bytes
        .try_into()
        .map_err(|_| anyhow!("WireGuard key must be 32 bytes of base64"))
}
pub(crate) fn cidr(value: &str) -> Result<IpCidr> {
    value
        .parse()
        .map_err(|_| anyhow!("Invalid IP address/prefix"))
}
impl BridgeConfig {
    pub fn parse(value: &str) -> Result<Self> {
        serde_json::from_str(value).map_err(|_| anyhow!("Invalid WireGuard configuration JSON"))
    }
    pub fn mtu(&self) -> usize {
        if self.mtu == 0 {
            1420
        } else {
            self.mtu as usize
        }
    }
    pub fn validate(&self) -> Result<()> {
        if self.address.is_empty()
            || self.address.len() > 8
            || self.peers.is_empty()
            || self.peers.len() > 64
        {
            return Err(anyhow!("1..8 addresses and 1..64 peers required"));
        }
        key(&self.private_key)?;
        if self.mtu() < 576 {
            return Err(anyhow!("MTU must be 576..65535"));
        }
        let mut addresses = HashSet::new();
        for address in &self.address {
            let ip = cidr(address)?.address();
            if ip.is_unspecified() || !ip.is_unicast() || !addresses.insert(ip) {
                return Err(anyhow!("Invalid or duplicate tunnel address"));
            }
        }
        let mut keys = HashSet::new();
        for peer in &self.peers {
            if !keys.insert(key(&peer.public_key)?) {
                return Err(anyhow!("Duplicate peer key"));
            }
            if let Some(psk) = peer.preshared_key.as_deref().filter(|v| !v.is_empty()) {
                key(psk)?;
            }
            if peer.allowed_ips.is_empty() || peer.allowed_ips.len() > 256 {
                return Err(anyhow!("1..256 AllowedIPs per peer required"));
            }
            for allowed in &peer.allowed_ips {
                cidr(allowed)?;
            }
            if let Some(endpoint) = peer.endpoint.as_deref().filter(|v| !v.is_empty()) {
                let (_, port) = endpoint
                    .rsplit_once(':')
                    .ok_or_else(|| anyhow!("Invalid peer endpoint"))?;
                if port.parse::<u16>().ok().filter(|port| *port != 0).is_none() {
                    return Err(anyhow!("Invalid peer endpoint port"));
                }
            }
        }
        Ok(())
    }
}
pub(crate) fn parse_routes(value: &str) -> Result<Vec<ServiceRoute>> {
    serde_json::from_str(value).map_err(|_| anyhow!("Invalid service routes JSON"))
}
pub(crate) fn validate_routes(routes: &[ServiceRoute]) -> Result<()> {
    if routes.is_empty() || routes.len() > 16 {
        return Err(anyhow!("1..16 service routes required"));
    }
    let mut ports = HashSet::new();
    for route in routes {
        if route.port == 0 || route.local_port == 0 {
            return Err(anyhow!("Invalid service port"));
        }
        if !ports.insert(route.port) {
            return Err(anyhow!("Duplicate service port"));
        }
        route.local_addr()?;
    }
    Ok(())
}
