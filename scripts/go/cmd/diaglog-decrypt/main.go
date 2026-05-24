// Command diaglog-decrypt decrypts a AppDiagLog export ZIP offline using
// private keys from a keys.json file.
//
// Dispatches on the algorithm strings carried in the envelope:
//
//	symmetric AEAD:  AES-256-GCM, AES-128-GCM, ChaCha20-Poly1305
//	asymmetric KEK:  ML-KEM-768, ML-KEM-512, RSA-OAEP-3072, ECDH-P256+HKDF
//
// Exit codes:
//
//	0  all sessions decrypted
//	1  partial success (failures printed to stderr)
//	2  no sessions decrypted (wrong keys, empty ZIP, missing deps)
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/appdiaglog/diaglog-decrypt/internal/cli"
)

func main() {
	var (
		zipPath = flag.String("zip", "", "Path to the exported ZIP.")
		keys    = flag.String("keys", "", "JSON file mapping key_id → base64 PKCS#8 private key.")
		out     = flag.String("out", "", "Output directory.")
		format  = flag.String("format", "jsonl", "Output format: jsonl | csv | combined | xls.")
	)
	flag.Parse()

	if *zipPath == "" || *keys == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: diaglog-decrypt --zip EXPORT.zip --keys KEYS.json --out DIR [--format jsonl|csv|combined|xls]")
		os.Exit(2)
	}

	exitCode, err := cli.Run(cli.Options{
		ZipPath: *zipPath,
		KeysPath: *keys,
		OutDir:  *out,
		Format:  *format,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "fatal: %v\n", err)
		os.Exit(2)
	}
	os.Exit(exitCode)
}
