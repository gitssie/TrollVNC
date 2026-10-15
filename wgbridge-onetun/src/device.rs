use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;
use std::collections::VecDeque;

const QUEUE_LIMIT: usize = 64;
pub(crate) struct PacketDevice {
    pub incoming: VecDeque<Vec<u8>>,
    pub outgoing: VecDeque<Vec<u8>>,
    mtu: usize,
}
impl PacketDevice {
    pub fn new(mtu: usize) -> Self {
        Self {
            incoming: VecDeque::new(),
            outgoing: VecDeque::new(),
            mtu,
        }
    }
    pub fn receive_packet(&mut self, packet: &[u8]) {
        if packet.len() <= self.mtu && self.incoming.len() < QUEUE_LIMIT {
            self.incoming.push_back(packet.to_vec());
        }
    }
}
pub(crate) struct Rx(Vec<u8>);
impl RxToken for Rx {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}
pub(crate) struct Tx<'a>(&'a mut VecDeque<Vec<u8>>);
impl TxToken for Tx<'_> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut bytes = vec![0; len];
        let result = f(&mut bytes);
        if self.0.len() < QUEUE_LIMIT {
            self.0.push_back(bytes);
        }
        result
    }
}
impl Device for PacketDevice {
    type RxToken<'a> = Rx;
    type TxToken<'a> = Tx<'a>;
    fn receive(&mut self, _: Instant) -> Option<(Rx, Tx<'_>)> {
        if self.outgoing.len() >= QUEUE_LIMIT {
            return None;
        }
        self.incoming
            .pop_front()
            .map(|packet| (Rx(packet), Tx(&mut self.outgoing)))
    }
    fn transmit(&mut self, _: Instant) -> Option<Tx<'_>> {
        (self.outgoing.len() < QUEUE_LIMIT).then_some(Tx(&mut self.outgoing))
    }
    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = self.mtu;
        caps.max_burst_size = Some(32);
        caps
    }
}
