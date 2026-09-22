package software

import (
	"context"
	"reflect"
	"testing"
	"time"
)

func TestProgressFromLine(t *testing.T) {
	tests := []struct {
		line string
		want int
		ok   bool
	}{
		{"(1/2) installing kitty [################] 73%", 73, true},
		{"Installing… ████████████████████ 100%", 100, true},
		{"download 7% verify 42%", 42, true},
		{"Сборка AUR-пакета: kitty", 0, false},
	}
	for _, test := range tests {
		got, ok := progressFromLine(test.line)
		if got != test.want || ok != test.ok {
			t.Fatalf("progressFromLine(%q) = (%d, %v), want (%d, %v)", test.line, got, ok, test.want, test.ok)
		}
	}
}

func TestStageFromLine(t *testing.T) {
	for line, want := range map[string]string{
		"downloading kitty":      "Загрузка пакета",
		"(1/1) installing kitty": "Установка пакета",
		"Проверка ключей":        "Проверка пакета",
		"Сборка AUR-пакета":      "Сборка пакета",
	} {
		if got := stageFromLine(line); got != want {
			t.Fatalf("stageFromLine(%q) = %q, want %q", line, got, want)
		}
	}
}

func TestOperationsAreQueuedAndRunInOrder(t *testing.T) {
	manager := &Manager{state: OperationState{Phase: PhaseIdle}}
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	done := make(chan struct{})
	var order []string

	if err := manager.start("install", Item{ID: "one", PackageName: "one", Source: SourcePacman}, func(context.Context, func(string)) error {
		close(firstStarted)
		<-releaseFirst
		order = append(order, "one")
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	<-firstStarted
	if err := manager.start("install", Item{ID: "two", PackageName: "two", Source: SourceFlatpak}, func(context.Context, func(string)) error {
		order = append(order, "two")
		close(done)
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	state := manager.State()
	if len(state.Queue) != 1 || state.Queue[0].Item.PackageName != "two" || state.Total != 2 {
		t.Fatalf("unexpected queued state: %#v", state)
	}
	close(releaseFirst)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("queued operation did not start")
	}

	deadline := time.Now().Add(2 * time.Second)
	for manager.State().Phase != PhaseComplete && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	state = manager.State()
	if !reflect.DeepEqual(order, []string{"one", "two"}) {
		t.Fatalf("operation order = %v", order)
	}
	if state.Completed != 2 || state.Total != 2 || state.Failed != 0 || len(state.Queue) != 0 {
		t.Fatalf("unexpected final state: %#v", state)
	}
}
