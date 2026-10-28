// check-buildkitd-config decodes a buildkitd.toml strictly against BuildKit's own
// config struct. buildkitd silently ignores unknown keys, so a typo would turn a
// setting off without any error; this tool turns that into a CI failure.
//
//	cd tools/check-buildkitd-config && go run . ../../infra/buildkit/buildkitd.toml   (make check-config)
package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"

	"github.com/moby/buildkit/cmd/buildkitd/config"
	"github.com/pelletier/go-toml/v2"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: check-buildkitd-config <buildkitd.toml>")
		os.Exit(2)
	}
	dt, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var c config.Config
	dec := toml.NewDecoder(bytes.NewReader(dt))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		var strict *toml.StrictMissingError
		if errors.As(err, &strict) {
			fmt.Fprintln(os.Stderr, strict.String())
		}
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	// The loader buildkitd itself uses: catches bad sizes and durations.
	if _, err := config.Load(bytes.NewReader(dt)); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	if c.History == nil || c.History.MaxEntries == nil || c.History.MaxAge.Duration == 0 {
		fmt.Fprintln(os.Stderr, "error: [history] must set both maxAge and maxEntries")
		os.Exit(1)
	}
	if c.GRPC.TLS.CA == "" {
		fmt.Fprintln(os.Stderr, "error: [grpc.tls] ca must be set (mTLS)")
		os.Exit(1)
	}
	fmt.Printf("ok: %d gc policies, %d registries, max-parallelism %d\n",
		len(c.Workers.OCI.GCPolicy), len(c.Registries), c.Workers.OCI.MaxParallelism)
}
