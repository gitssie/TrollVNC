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

func TestUserspaceBridgeForwardsIndependentServicesOverWireGuard(t *testing.T) {
	local, err := net.Listen("tcp", "[::1]:0")
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	port := local.Addr().(*net.TCPAddr).Port
	go func() {
		for {
			c, err := local.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()

	zxLocal, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer zxLocal.Close()
	zxPort := zxLocal.Addr().(*net.TCPAddr).Port
	go func() {
		for {
			c, err := zxLocal.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); c.Write([]byte("ZX")); io.Copy(c, c) }()
		}
	}()

	curve := ecdh.X25519()
	phoneKey, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	computerKey, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	udp, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	computerPort := udp.LocalAddr().(*net.UDPAddr).Port
	udp.Close()

	computerTun, computerNet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.99.0.1")}, nil, 1420)
	if err != nil {
		t.Fatal(err)
	}
	computer := device.NewDevice(computerTun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "test: "))
	defer computer.Close()
	computerIPC := fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.99.0.2/32\n",
		hex.EncodeToString(computerKey.Bytes()), computerPort, hex.EncodeToString(phoneKey.PublicKey().Bytes()))
	if err := computer.IpcSet(computerIPC); err != nil {
		t.Fatal(err)
	}
	if err := computer.Up(); err != nil {
		t.Fatal(err)
	}

	config := bridgeConfig{
		Address:    []string{"10.99.0.2/32"},
		PrivateKey: base64.StdEncoding.EncodeToString(phoneKey.Bytes()),
		Peers: []peerConfig{{
			PublicKey:           base64.StdEncoding.EncodeToString(computerKey.PublicKey().Bytes()),
			Endpoint:            fmt.Sprintf("127.0.0.1:%d", computerPort),
			AllowedIPs:          []string{"10.99.0.1/32"},
			PersistentKeepalive: 1,
		}},
	}
	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	routes := []serviceRoute{{Port: port, LocalPort: port, LocalHost: "::1"}, {Port: 6000, LocalPort: zxPort}}
	if port == 6000 {
		routes[1].Port = 6001
	}
	if err := startServices(raw, routes); err != nil {
		t.Fatal(err)
	}
	if err := startServices(raw, routes); err == nil {
		t.Fatal("second start must fail")
	}
	defer stop()

	var connection net.Conn
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		connection, err = computerNet.DialContextTCP(ctx, &net.TCPAddr{IP: net.ParseIP("10.99.0.2"), Port: port})
		cancel()
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("WireGuard connection never reached VNC: %v", err)
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := connection.Write([]byte("VNC")); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 3)
	if _, err := io.ReadFull(connection, response); err != nil {
		t.Fatal(err)
	}
	if string(response) != "VNC" {
		t.Fatalf("got %q", response)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	zxConnection, err := computerNet.DialContextTCP(ctx, &net.TCPAddr{IP: net.ParseIP("10.99.0.2"), Port: routes[1].Port})
	cancel()
	if err != nil {
		t.Fatal(err)
	}
	defer zxConnection.Close()
	zxConnection.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := zxConnection.Write([]byte("251\r\n")); err != nil {
		t.Fatal(err)
	}
	zxResponse := make([]byte, 7)
	if _, err := io.ReadFull(zxConnection, zxResponse); err != nil {
		t.Fatal(err)
	}
	if string(zxResponse) != "ZX251\r\n" {
		t.Fatalf("ZXTouch crossed service routes: %q", zxResponse)
	}
	// Stopping the shared tunnel must close already accepted connections as well.
	stop()
	connection.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := connection.Read(make([]byte, 1)); err == nil {
		t.Fatal("stop left VNC connection open")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("stop did not close VNC connection before deadline")
	}
	zxConnection.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := zxConnection.Read(make([]byte, 1)); err == nil {
		t.Fatal("stop left ZXTouch connection open")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("stop did not close ZXTouch connection before deadline")
	}
	// ZXTouch can keep the network endpoint without a VNC route.
	if err := startServices(raw, routes[1:]); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(8 * time.Second)
	var zxOnly net.Conn
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		zxOnly, err = computerNet.DialContextTCP(ctx, &net.TCPAddr{IP: net.ParseIP("10.99.0.2"), Port: routes[1].Port})
		cancel()
		if err == nil {
			break
		}
	}
	if err != nil {
		t.Fatalf("ZXTouch-only tunnel failed: %v", err)
	}
	defer zxOnly.Close()
	zxOnly.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := io.ReadFull(zxOnly, make([]byte, 2)); err != nil {
		t.Fatal(err)
	}

}

func TestServiceRoutesRejectInvalidPorts(t *testing.T) {
	for _, routes := range [][]serviceRoute{
		nil, {{Port: 6000, LocalPort: 6000, LocalHost: "192.168.1.2"}}, {{Port: 0, LocalPort: 1}}, {{Port: 6000, LocalPort: 65536}},
		{{Port: 6000, LocalPort: 6000}, {Port: 6000, LocalPort: 5901}},
	} {
		if err := startServices(nil, routes); err == nil {
			t.Fatalf("accepted invalid routes: %v", routes)
		}
	}
}
