package main

import (
	"avenkin.dev/mobilecore/labprobe"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/syncthing/syncthing/lib/protocol"
	"os"
	"time"
)

func main() {
	root := flag.String("run-directory", "", "New private run directory")
	address := flag.String("listen", "", "Explicit private LAN IP:port")
	phone := flag.String("phone-id", "", "Explicit approved phone transport fingerprint")
	flag.Parse()
	id, err := protocol.DeviceIDFromString(*phone)
	if err != nil || id == protocol.EmptyDeviceID || *root == "" || *address == "" {
		fmt.Fprintln(os.Stderr, "Invalid manual probe arguments")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	report, err := labprobe.Run(ctx, *root, *address, id)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	raw, _ := json.MarshalIndent(report, "", "  ")
	fmt.Println(string(raw))
}
