// Package main provides a userspace WireGuard listener for TrollVNC. It does
// not create a system TUN interface or alter iOS routes.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type peerConfig struct {
	PublicKey           string   `json:"PublicKey"`
	PresharedKey        string   `json:"PresharedKey"`
	Endpoint            string   `json:"Endpoint"`
	AllowedIPs          []string `json:"AllowedIPs"`
	PersistentKeepalive int      `json:"PersistentKeepalive"`
}

type bridgeConfig struct {
	Address    []string     `json:"Address"`
	PrivateKey string       `json:"PrivateKey"`
	ListenPort int          `json:"ListenPort"`
	MTU        int          `json:"MTU"`
	Peers      []peerConfig `json:"Peers"`
}

type bridge struct {
	listener net.Listener
	device   *device.Device
	tun      tun.Device
}

var state struct {
	sync.Mutex
	active *bridge
}

func keyHex(value string) (string, error) {
	bytes, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(bytes) != 32 {
		return "", errors.New("WireGuard key must be 32 bytes of base64")
	}
	return hex.EncodeToString(bytes), nil
}

func parseConfig(raw []byte) (bridgeConfig, []netip.Addr, string, error) {
	var cfg bridgeConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, nil, "", fmt.Errorf("invalid WireGuard settings: %w", err)
	}
	if len(cfg.Address) == 0 || len(cfg.Peers) == 0 {
		return cfg, nil, "", errors.New("Address and at least one Peer are required")
	}
	privateKey, err := keyHex(cfg.PrivateKey)
	if err != nil {
		return cfg, nil, "", fmt.Errorf("PrivateKey: %w", err)
	}
	addresses := make([]netip.Addr, 0, len(cfg.Address))
	for _, value := range cfg.Address {
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return cfg, nil, "", fmt.Errorf("invalid Address: %w", err)
		}
		addresses = append(addresses, prefix.Addr())
	}
	if cfg.MTU == 0 {
		cfg.MTU = 1420
	}
	if cfg.MTU < 576 || cfg.MTU > 65535 {
		return cfg, nil, "", errors.New("MTU must be 576..65535")
	}
	if cfg.ListenPort < 0 || cfg.ListenPort > 65535 {
		return cfg, nil, "", errors.New("ListenPort must be 0..65535")
	}
	var ipc strings.Builder
	fmt.Fprintf(&ipc, "private_key=%s\nlisten_port=%d\nreplace_peers=true\n", privateKey, cfg.ListenPort)
	for i, peer := range cfg.Peers {
		publicKey, err := keyHex(peer.PublicKey)
		if err != nil {
			return cfg, nil, "", fmt.Errorf("Peer %d PublicKey: %w", i+1, err)
		}
		fmt.Fprintf(&ipc, "public_key=%s\n", publicKey)
		if peer.PresharedKey != "" {
			psk, err := keyHex(peer.PresharedKey)
			if err != nil {
				return cfg, nil, "", fmt.Errorf("Peer %d PresharedKey: %w", i+1, err)
			}
			fmt.Fprintf(&ipc, "preshared_key=%s\n", psk)
		}
		if peer.Endpoint != "" {
			host, port, err := net.SplitHostPort(peer.Endpoint)
			if err != nil || host == "" {
				return cfg, nil, "", fmt.Errorf("Peer %d has an invalid Endpoint", i+1)
			}
			p, err := strconv.Atoi(port)
			if err != nil || p < 1 || p > 65535 {
				return cfg, nil, "", fmt.Errorf("Peer %d has an invalid Endpoint port", i+1)
			}
			fmt.Fprintf(&ipc, "endpoint=%s\n", peer.Endpoint)
		}
		if peer.PersistentKeepalive < 0 || peer.PersistentKeepalive > 65535 {
			return cfg, nil, "", fmt.Errorf("Peer %d has an invalid PersistentKeepalive", i+1)
		}
		fmt.Fprintf(&ipc, "persistent_keepalive_interval=%d\n", peer.PersistentKeepalive)
		if len(peer.AllowedIPs) == 0 {
			return cfg, nil, "", fmt.Errorf("Peer %d needs AllowedIPs", i+1)
		}
		for _, cidr := range peer.AllowedIPs {
			prefix, err := netip.ParsePrefix(cidr)
			if err != nil {
				return cfg, nil, "", fmt.Errorf("Peer %d has invalid AllowedIPs: %w", i+1, err)
			}
			fmt.Fprintf(&ipc, "allowed_ip=%s\n", prefix.String())
		}
	}
	return cfg, addresses, ipc.String(), nil
}

func start(raw []byte, vncPort int) error {
	if vncPort < 1 || vncPort > 65535 {
		return errors.New("invalid VNC port")
	}
	cfg, addresses, ipc, err := parseConfig(raw)
	if err != nil {
		return err
	}
	tunDevice, network, err := netstack.CreateNetTUN(addresses, nil, cfg.MTU)
	if err != nil {
		return err
	}
	wg := device.NewDevice(tunDevice, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "TrollVNC WG: "))
	if err = wg.IpcSet(ipc); err == nil {
		err = wg.Up()
	}
	if err != nil {
		wg.Close()
		return err
	}
	listener, err := network.ListenTCP(&net.TCPAddr{Port: vncPort})
	if err != nil {
		wg.Close()
		return err
	}
	b := &bridge{listener: listener, device: wg, tun: tunDevice}
	state.Lock()
	if state.active != nil {
		state.Unlock()
		listener.Close()
		wg.Close()
		return errors.New("WireGuard bridge is already running")
	}
	state.active = b
	state.Unlock()
	go b.serve(vncPort)
	return nil
}

func (b *bridge) serve(port int) {
	for {
		incoming, err := b.listener.Accept()
		if err != nil {
			return
		}
		go func() {
			local, err := net.Dial("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
			if err != nil {
				local, err = net.Dial("tcp", net.JoinHostPort("::1", strconv.Itoa(port)))
			}
			if err != nil {
				incoming.Close()
				return
			}
			defer incoming.Close()
			defer local.Close()
			done := make(chan struct{}, 2)
			go func() { io.Copy(local, incoming); done <- struct{}{} }()
			go func() { io.Copy(incoming, local); done <- struct{}{} }()
			<-done
		}()
	}
}

func stop() {
	state.Lock()
	b := state.active
	state.active = nil
	state.Unlock()
	if b != nil {
		b.listener.Close()
		b.device.Close()
	}
}

//export TVNCWGStart
func TVNCWGStart(config *C.char, port C.int) *C.char {
	if config == nil {
		return C.CString("WireGuard configuration is missing")
	}
	if err := start([]byte(C.GoString(config)), int(port)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export TVNCWGStop
func TVNCWGStop() { stop() }

//export TVNCWGFree
func TVNCWGFree(value *C.char) { C.free(unsafe.Pointer(value)) }

func main() {}
