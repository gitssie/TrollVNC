package main

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func TestUserspaceBridgeForwardsVNCOverWireGuard(t *testing.T) {
	local, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	defer local.Close()
	port := local.Addr().(*net.TCPAddr).Port
	go func() {
		for {
			c, err := local.Accept()
			if err != nil { return }
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()

	curve := ecdh.X25519()
	phoneKey, err := curve.GenerateKey(rand.Reader)
	if err != nil { t.Fatal(err) }
	computerKey, err := curve.GenerateKey(rand.Reader)
	if err != nil { t.Fatal(err) }

	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil { t.Fatal(err) }
	computerPort := udp.LocalAddr().(*net.UDPAddr).Port
	udp.Close()

	computerTun, computerNet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.99.0.1")}, nil, 1420)
	if err != nil { t.Fatal(err) }
	computer := device.NewDevice(computerTun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "test: "))
	defer computer.Close()
	computerIPC := fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.99.0.2/32\n",
		hex.EncodeToString(computerKey.Bytes()), computerPort, hex.EncodeToString(phoneKey.PublicKey().Bytes()))
	if err := computer.IpcSet(computerIPC); err != nil { t.Fatal(err) }
	if err := computer.Up(); err != nil { t.Fatal(err) }

	config := bridgeConfig{
		Address: []string{"10.99.0.2/32"},
		PrivateKey: base64.StdEncoding.EncodeToString(phoneKey.Bytes()),
		Peers: []peerConfig{{
			PublicKey: base64.StdEncoding.EncodeToString(computerKey.PublicKey().Bytes()),
			Endpoint: fmt.Sprintf("127.0.0.1:%d", computerPort),
			AllowedIPs: []string{"10.99.0.1/32"},
			PersistentKeepalive: 1,
		}},
	}
	raw, err := json.Marshal(config)
	if err != nil { t.Fatal(err) }
	if err := start(raw, port); err != nil { t.Fatal(err) }
	defer stop()

	var connection net.Conn
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		connection, err = computerNet.DialContextTCP(ctx, &net.TCPAddr{IP: net.ParseIP("10.99.0.2"), Port: port})
		cancel()
		if err == nil { break }
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil { t.Fatalf("WireGuard connection never reached VNC: %v", err) }
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := connection.Write([]byte("VNC")); err != nil { t.Fatal(err) }
	response := make([]byte, 3)
	if _, err := io.ReadFull(connection, response); err != nil { t.Fatal(err) }
	if string(response) != "VNC" { t.Fatalf("got %q", response) }
}
