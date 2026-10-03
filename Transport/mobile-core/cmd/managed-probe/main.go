// managed-probe is a local two-process transport check, not an enrolment path.
// It deliberately bypasses vendor binding verification and must never ship in the app.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"avenkin.dev/mobilecore"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: managed-probe id HOME | connect HOME OFFICE_ID ADDRESS STATUS_FILE STOP_FILE | connect-route HOME OFFICE_ID POLICY HINT|- STATUS_FILE STOP_FILE")
	}
	client, err := mobilecore.NewClient(args[1])
	if err != nil {
		return err
	}
	if args[0] == "id" && len(args) == 2 {
		fmt.Println(client.DeviceID())
		return nil
	}
	var files []string
	wait := 25 * time.Second
	switch {
	case args[0] == "connect" && len(args) == 6:
		err = client.StartManagedOffice(args[2], args[3])
		files = args[4:]
	case args[0] == "connect-route" && len(args) == 7:
		// POLICY is privateLan or automatic; "-" stands for no LAN hint.
		hint := args[4]
		if hint == "-" {
			hint = ""
		}
		err = client.StartManagedOfficeRoute(args[2], args[3], hint)
		files = args[5:]
		// Discovery keeps a failed lookup for a minute, so an office that announces after the
		// phone's first lookup is found on the next one.
		wait = 150 * time.Second
	default:
		return fmt.Errorf("invalid managed-probe arguments")
	}
	if err != nil {
		return err
	}
	defer client.Stop()
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		raw, err := client.Snapshot()
		if err != nil {
			return err
		}
		var status struct {
			Connected     bool `json:"connected"`
			ManagedOffice bool `json:"managedOffice"`
			SharedFolders int  `json:"sharedFolders"`
		}
		if err := json.Unmarshal([]byte(raw), &status); err != nil {
			return err
		}
		if status.Connected {
			if !status.ManagedOffice || status.SharedFolders != 0 {
				return fmt.Errorf("connected with unexpected managed policy: %s", raw)
			}
			if err := os.WriteFile(files[0], []byte(raw), 0600); err != nil {
				return err
			}
			for time.Now().Before(deadline) {
				if _, err := os.Stat(files[1]); err == nil {
					return nil
				} else if !os.IsNotExist(err) {
					return err
				}
				time.Sleep(100 * time.Millisecond)
			}
			return fmt.Errorf("timed out waiting for probe stop")
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("managed phone did not connect within %v", wait)
}
