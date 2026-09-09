package network

import (
	"fmt"
	"net"
	"strings"

	"github.com/godbus/dbus/v5"
)

func interfaceIPv4(ifname string) string {
	iface, err := net.InterfaceByName(ifname)
	if err != nil {
		return ""
	}

	addrs, err := iface.Addrs()
	if err != nil {
		return ""
	}

	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		if ipv4 := ipnet.IP.To4(); ipv4 != nil {
			return ipv4.String()
		}
	}
	return ""
}

func looksWirelessName(name string) bool {
	return strings.HasPrefix(name, "wlan") || strings.HasPrefix(name, "wlp")
}

func (b *WpaSupplicantBackend) isWpaManaged(name string) bool {
	return name == b.ifname
}

func (b *WpaSupplicantBackend) ethernetDevices() []EthernetDevice {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}

	var devices []EthernetDevice
	for _, iface := range ifaces {
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if looksVirtual(iface.Name) || looksWirelessName(iface.Name) {
			continue
		}
		if b.isWpaManaged(iface.Name) {
			continue
		}

		up := iface.Flags&net.FlagUp != 0
		running := iface.Flags&net.FlagRunning != 0
		ip := interfaceIPv4(iface.Name)

		stateStr := "off"
		switch {
		case running && ip != "":
			stateStr = "routable"
		case running:
			stateStr = "carrier"
		case up:
			stateStr = "no-carrier"
		}

		devices = append(devices, EthernetDevice{
			Name:      iface.Name,
			HwAddress: iface.HardwareAddr.String(),
			State:     stateStr,
			Connected: up && running,
			IP:        ip,
		})
	}
	return devices
}

func wiredConnectionsFromEthernetDevices(devices []EthernetDevice) []WiredConnection {
	conns := make([]WiredConnection, 0, len(devices))
	for _, dev := range devices {
		conns = append(conns, WiredConnection{
			Path:     dbus.ObjectPath("/" + dev.Name),
			ID:       dev.Name,
			UUID:     "wired:" + dev.Name,
			Type:     "ethernet",
			IsActive: dev.Connected,
		})
	}
	return conns
}

func (b *WpaSupplicantBackend) GetEthernetDevices() []EthernetDevice {
	b.stateMutex.RLock()
	defer b.stateMutex.RUnlock()
	return append([]EthernetDevice(nil), b.state.EthernetDevices...)
}

func (b *WpaSupplicantBackend) GetWiredConnections() ([]WiredConnection, error) {
	return wiredConnectionsFromEthernetDevices(b.ethernetDevices()), nil
}

func (b *WpaSupplicantBackend) GetWiredNetworkDetails(id string) (*WiredNetworkInfoResponse, error) {
	ifname := strings.TrimPrefix(id, "wired:")

	iface, err := net.InterfaceByName(ifname)
	if err != nil {
		return nil, fmt.Errorf("get interface: %w", err)
	}

	addrs, _ := iface.Addrs()
	var ipv4s, ipv6s []string
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		if ipv4 := ipnet.IP.To4(); ipv4 != nil {
			ipv4s = append(ipv4s, ipnet.String())
		} else if ipv6 := ipnet.IP.To16(); ipv6 != nil {
			ipv6s = append(ipv6s, ipnet.String())
		}
	}

	return &WiredNetworkInfoResponse{
		UUID:   id,
		IFace:  ifname,
		HwAddr: iface.HardwareAddr.String(),
		IPv4: WiredIPConfig{
			IPs: ipv4s,
		},
		IPv6: WiredIPConfig{
			IPs: ipv6s,
		},
	}, nil
}
