// Command diaglog-keygen generates an asymmetric keypair for the AppDiagLog
// SDK. The public key is embedded in the app at build time; the private key is
// kept on the backend or in a local keys.json for offline decryption.
//
// Usage:
//
//	diaglog-keygen --key-id KEY_ID --out DIR [--algorithm ALGORITHM]
//
// Exit codes:
//
//	0  keypair written successfully
//	1  generation or I/O error
//	2  bad arguments
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/appdiaglog/diaglog-decrypt/internal/keygen"
)

func main() {
	algorithm := flag.String(
		"algorithm", "ML-KEM-768",
		"KEK algorithm: ML-KEM-768 | ML-KEM-512 | RSA-OAEP-3072 | ECDH-P256+HKDF",
	)
	keyID := flag.String(
		"key-id", "",
		"Logical key identifier, e.g. key-2026-06. Must be unique per backend deployment.",
	)
	out := flag.String(
		"out", "",
		"Output directory. keys.json is created/updated; <key-id>.pub.b64 is written.",
	)
	flag.Parse()

	if *keyID == "" || *out == "" {
		fmt.Fprintln(os.Stderr,
			"usage: diaglog-keygen --key-id KEY_ID --out DIR [--algorithm ML-KEM-768|ML-KEM-512|RSA-OAEP-3072|ECDH-P256+HKDF]")
		os.Exit(2)
	}

	if err := keygen.Run(*algorithm, *keyID, *out); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
