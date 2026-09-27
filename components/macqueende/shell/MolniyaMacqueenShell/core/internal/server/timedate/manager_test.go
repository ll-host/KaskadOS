package timedate

import (
	"os"
	"testing"
)

func TestSystemTimeStatus(t *testing.T) {
	if os.Getenv("KASKADOS_TEST_TIMEDATE") != "1" {
		t.Skip("set KASKADOS_TEST_TIMEDATE=1 to test the local timedate service")
	}
	manager, err := NewManager()
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	state, err := manager.Status()
	if err != nil {
		t.Fatal(err)
	}
	if state.Timezone == "" {
		t.Fatal("system time service returned an empty timezone")
	}
	unchanged, err := manager.SetAutomatic(state.Automatic)
	if err != nil {
		t.Fatal(err)
	}
	if unchanged.Automatic != state.Automatic {
		t.Fatalf("automatic time changed during a read-only check: %v -> %v", state.Automatic, unchanged.Automatic)
	}
}
