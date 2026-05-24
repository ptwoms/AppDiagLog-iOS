// Package cli ties parsing, dispatching, and output writers together.
package cli

import (
	"archive/zip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/appdiaglog/diaglog-decrypt/internal/envelope"
	"github.com/appdiaglog/diaglog-decrypt/internal/output"
	"github.com/appdiaglog/diaglog-decrypt/internal/pipeline"
)

// Options collects the CLI flags so [main] stays trivial.
type Options struct {
	ZipPath  string
	KeysPath string
	OutDir   string
	Format   string // "jsonl" | "csv"
}

// Run executes the full pipeline. Returns the process exit code.
func Run(opts Options) (int, error) {
	keys, err := loadKeys(opts.KeysPath)
	if err != nil {
		return 2, fmt.Errorf("loading keys: %w", err)
	}

	envelopes, err := readEnvelopes(opts.ZipPath)
	if err != nil {
		return 2, fmt.Errorf("reading zip: %w", err)
	}
	if len(envelopes) == 0 {
		fmt.Fprintln(os.Stderr, "No session envelopes found in the ZIP.")
		return 2, nil
	}

	if err := os.MkdirAll(opts.OutDir, 0o755); err != nil {
		return 2, fmt.Errorf("creating out dir: %w", err)
	}

	writer, err := output.New(opts.Format, opts.OutDir)
	if err != nil {
		return 2, err
	}
	defer writer.Close()

	var (
		successes []string
		failures  []failure
	)
	for _, env := range envelopes {
		events, err := pipeline.DecryptEnvelope(env, keys)
		if err != nil {
			failures = append(failures, failure{env.SessionID, err.Error()})
			continue
		}
		if len(events) == 0 {
			continue // empty, cleanly-sealed session — nothing to write
		}
		if err := writer.Write(env, events); err != nil {
			failures = append(failures, failure{env.SessionID, "write: " + err.Error()})
			continue
		}
		successes = append(successes, env.SessionID)
	}

	fmt.Printf("Decrypted: %d sessions to %s\n", len(successes), opts.OutDir)
	if len(failures) > 0 {
		fmt.Fprintf(os.Stderr, "Failed: %d sessions\n", len(failures))
		for _, f := range failures {
			fmt.Fprintf(os.Stderr, "  - %s: %s\n", f.sessionID, f.reason)
		}
	}
	switch {
	case len(successes) == 0:
		return 2, nil
	case len(failures) > 0:
		return 1, nil
	default:
		return 0, nil
	}
}

type failure struct {
	sessionID string
	reason    string
}

func loadKeys(path string) (map[string][]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var parsed map[string]string
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, fmt.Errorf("keys.json is not a string map: %w", err)
	}
	out := make(map[string][]byte, len(parsed))
	for k, v := range parsed {
		decoded, err := base64.StdEncoding.DecodeString(v)
		if err != nil {
			return nil, fmt.Errorf("key %q is not base64: %w", k, err)
		}
		out[k] = decoded
	}
	return out, nil
}

func readEnvelopes(path string) ([]envelope.Envelope, error) {
	r, err := zip.OpenReader(path)
	if err != nil {
		return nil, err
	}
	defer r.Close()

	var envelopes []envelope.Envelope
	for _, f := range r.File {
		dir, name := filepath.Split(f.Name)
		if dir != "sessions/" || filepath.Ext(name) != ".enc" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, err
		}
		buf, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return nil, err
		}
		var env envelope.Envelope
		if err := json.Unmarshal(buf, &env); err != nil {
			fmt.Fprintf(os.Stderr, "skipping malformed envelope %s: %v\n", f.Name, err)
			continue
		}
		envelopes = append(envelopes, env)
	}
	return envelopes, nil
}
