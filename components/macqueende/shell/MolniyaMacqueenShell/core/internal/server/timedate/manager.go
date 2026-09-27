package timedate

import (
	"errors"
	"fmt"
	"sync"

	"github.com/godbus/dbus/v5"
)

const (
	serviceName   = "org.freedesktop.timedate1"
	objectPath    = dbus.ObjectPath("/org/freedesktop/timedate1")
	interfaceName = "org.freedesktop.timedate1"
)

type State struct {
	Available    bool   `json:"available"`
	Automatic    bool   `json:"automatic"`
	Synchronized bool   `json:"synchronized"`
	Timezone     string `json:"timezone"`
}

type Manager struct {
	connection *dbus.Conn
	mu         sync.Mutex
}

func NewManager() (*Manager, error) {
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, fmt.Errorf("подключение к системной службе времени: %w", err)
	}
	manager := &Manager{connection: connection}
	if _, err := manager.Status(); err != nil {
		connection.Close()
		return nil, err
	}
	return manager, nil
}

func (m *Manager) Status() (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.statusLocked()
}

func (m *Manager) SetAutomatic(enabled bool) (State, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	state, err := m.statusLocked()
	if err != nil {
		return State{}, err
	}
	if !state.Available {
		return State{}, errors.New("автоматическая синхронизация времени недоступна")
	}
	if state.Automatic != enabled {
		call := m.connection.Object(serviceName, objectPath).Call(
			interfaceName+".SetNTP", dbus.FlagAllowInteractiveAuthorization, enabled, true)
		if call.Err != nil {
			return State{}, fmt.Errorf("изменение автоматической синхронизации времени: %w", call.Err)
		}
	}
	return m.statusLocked()
}

func (m *Manager) statusLocked() (State, error) {
	object := m.connection.Object(serviceName, objectPath)
	available, err := boolProperty(object, "CanNTP")
	if err != nil {
		return State{}, err
	}
	automatic, err := boolProperty(object, "NTP")
	if err != nil {
		return State{}, err
	}
	synchronized, err := boolProperty(object, "NTPSynchronized")
	if err != nil {
		return State{}, err
	}
	timezone, err := stringProperty(object, "Timezone")
	if err != nil {
		return State{}, err
	}
	return State{
		Available: available, Automatic: automatic,
		Synchronized: synchronized, Timezone: timezone,
	}, nil
}

func boolProperty(object dbus.BusObject, name string) (bool, error) {
	value, err := object.GetProperty(interfaceName + "." + name)
	if err != nil {
		return false, fmt.Errorf("чтение состояния времени %s: %w", name, err)
	}
	result, ok := value.Value().(bool)
	if !ok {
		return false, fmt.Errorf("системная служба времени вернула неверный тип свойства %s", name)
	}
	return result, nil
}

func stringProperty(object dbus.BusObject, name string) (string, error) {
	value, err := object.GetProperty(interfaceName + "." + name)
	if err != nil {
		return "", fmt.Errorf("чтение состояния времени %s: %w", name, err)
	}
	result, ok := value.Value().(string)
	if !ok {
		return "", fmt.Errorf("системная служба времени вернула неверный тип свойства %s", name)
	}
	return result, nil
}

func (m *Manager) Close() {
	if m != nil && m.connection != nil {
		m.connection.Close()
	}
}
