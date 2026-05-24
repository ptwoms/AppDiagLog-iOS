// Package keygen generates asymmetric keypairs for the AppDiagLog SDK.
//
// Output encoding:
//   - ML-KEM-768 / ML-KEM-512: raw binary (circl MarshalBinary).
//     The decrypt pipeline accepts this directly; the SDK passes the raw bytes
//     to its liboqs/circl wrapper.
//   - RSA-OAEP-3072 / ECDH-P256+HKDF: PKCS#8 DER private key,
//     SubjectPublicKeyInfo DER public key — standard JVM-compatible encoding.
package keygen

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	mlkem512pkg "github.com/cloudflare/circl/kem/mlkem/mlkem512"
	mlkem768pkg "github.com/cloudflare/circl/kem/mlkem/mlkem768"
)

// KeyPair holds raw key material produced by [Generate].
type KeyPair struct {
	Algorithm       string
	KeyID           string
	PublicKeyBytes  []byte // embed in SDK PQCPublicKey.keyBytes (base64-encoded)
	PrivateKeyBytes []byte // store in keys.json (base64-encoded)
}

// Generate creates a keypair for the requested algorithm.
func Generate(algorithm string) (*KeyPair, error) {
	switch algorithm {
	case "ML-KEM-768":
		return generateMlKem768()
	case "ML-KEM-512":
		return generateMlKem512()
	case "RSA-OAEP-3072":
		return generateRsaOaep3072()
	case "ECDH-P256+HKDF":
		return generateEcdhP256()
	}
	return nil, fmt.Errorf(
		"unsupported algorithm %q — choose from ML-KEM-768, ML-KEM-512, RSA-OAEP-3072, ECDH-P256+HKDF",
		algorithm,
	)
}

func generateMlKem768() (*KeyPair, error) {
	pub, priv, err := mlkem768pkg.GenerateKeyPair(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate ML-KEM-768 keypair: %w", err)
	}
	pubBytes, err := pub.MarshalBinary()
	if err != nil {
		return nil, fmt.Errorf("marshal ML-KEM-768 public key: %w", err)
	}
	privBytes, err := priv.MarshalBinary()
	if err != nil {
		return nil, fmt.Errorf("marshal ML-KEM-768 private key: %w", err)
	}
	return &KeyPair{Algorithm: "ML-KEM-768", PublicKeyBytes: pubBytes, PrivateKeyBytes: privBytes}, nil
}

func generateMlKem512() (*KeyPair, error) {
	pub, priv, err := mlkem512pkg.GenerateKeyPair(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate ML-KEM-512 keypair: %w", err)
	}
	pubBytes, err := pub.MarshalBinary()
	if err != nil {
		return nil, fmt.Errorf("marshal ML-KEM-512 public key: %w", err)
	}
	privBytes, err := priv.MarshalBinary()
	if err != nil {
		return nil, fmt.Errorf("marshal ML-KEM-512 private key: %w", err)
	}
	return &KeyPair{Algorithm: "ML-KEM-512", PublicKeyBytes: pubBytes, PrivateKeyBytes: privBytes}, nil
}

func generateRsaOaep3072() (*KeyPair, error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		return nil, fmt.Errorf("generate RSA-3072 key: %w", err)
	}
	privBytes, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("marshal RSA private key: %w", err)
	}
	pubBytes, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("marshal RSA public key: %w", err)
	}
	return &KeyPair{Algorithm: "RSA-OAEP-3072", PublicKeyBytes: pubBytes, PrivateKeyBytes: privBytes}, nil
}

func generateEcdhP256() (*KeyPair, error) {
	privateKey, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate ECDH-P256 key: %w", err)
	}
	privBytes, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, fmt.Errorf("marshal ECDH private key: %w", err)
	}
	pubBytes, err := x509.MarshalPKIXPublicKey(privateKey.PublicKey())
	if err != nil {
		return nil, fmt.Errorf("marshal ECDH public key: %w", err)
	}
	return &KeyPair{Algorithm: "ECDH-P256+HKDF", PublicKeyBytes: pubBytes, PrivateKeyBytes: privBytes}, nil
}

// Run generates a keypair and writes output files to outDir.
//
// Output files:
//   - keys.json         — private key appended/updated under keyID; pass to
//                         diaglog-decrypt --keys.
//   - <keyID>.pub.b64   — base64 public key; paste into SDK init config.
func Run(algorithm, keyID, outDir string) error {
	kp, err := Generate(algorithm)
	if err != nil {
		return err
	}
	kp.KeyID = keyID

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return fmt.Errorf("create output dir: %w", err)
	}

	pubB64 := base64.StdEncoding.EncodeToString(kp.PublicKeyBytes)
	privB64 := base64.StdEncoding.EncodeToString(kp.PrivateKeyBytes)

	// --- update keys.json (append-safe, restricted permissions) --------------
	keysPath := filepath.Join(outDir, "keys.json")
	keysMap := map[string]string{}
	if data, err := os.ReadFile(keysPath); err == nil {
		if jsonErr := json.Unmarshal(data, &keysMap); jsonErr != nil {
			fmt.Fprintf(os.Stderr, "WARNING: %s is not valid JSON — overwriting\n", keysPath)
			keysMap = map[string]string{}
		}
	}
	if _, exists := keysMap[keyID]; exists {
		fmt.Fprintf(os.Stderr, "WARNING: key_id %q already in keys.json — overwriting\n", keyID)
	}
	keysMap[keyID] = privB64
	keysJSON, err := json.MarshalIndent(keysMap, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal keys.json: %w", err)
	}
	// 0o600 — private key material must not be world-readable.
	if err := os.WriteFile(keysPath, append(keysJSON, '\n'), 0o600); err != nil {
		return fmt.Errorf("write keys.json: %w", err)
	}

	// --- write public key file -----------------------------------------------
	pubPath := filepath.Join(outDir, keyID+".pub.b64")
	if err := os.WriteFile(pubPath, []byte(pubB64+"\n"), 0o644); err != nil {
		return fmt.Errorf("write public key file: %w", err)
	}

	// --- human-friendly summary ----------------------------------------------
	fmt.Printf("Algorithm : %s\n", algorithm)
	fmt.Printf("Key ID    : %s\n", keyID)
	fmt.Printf("Private   : %s  (pass as --keys to diaglog-decrypt)\n", keysPath)
	fmt.Printf("Public    : %s  (embed in SDK init config)\n", pubPath)
	fmt.Println()
	printSDKSnippet(algorithm, keyID, pubB64)
	return nil
}

func printSDKSnippet(algorithm, keyID, pubB64 string) {
	preview := pubB64
	if len(preview) > 48 {
		preview = preview[:48] + "…"
	}
	fmt.Println("── SDK init snippet ──────────────────────────────────────────────────")
	fmt.Println("iOS (Swift):")
	fmt.Printf("  AppDiagLog.initialize(config: .init(\n")
	fmt.Printf("    pqcPublicKey: .init(\n")
	fmt.Printf("      algorithm: .%s,\n", swiftEnum(algorithm))
	fmt.Printf("      keyId:     %q,\n", keyID)
	fmt.Printf("      keyBytes:  Data(base64Encoded: %q)!,\n", preview)
	fmt.Printf("    ),\n")
	fmt.Printf("  ))\n")
	fmt.Println("─────────────────────────────────────────────────────────────────────")
}

func swiftEnum(algorithm string) string {
	switch algorithm {
	case "ML-KEM-768":
		return "mlKEM768"
	case "ML-KEM-512":
		return "mlKEM512"
	case "RSA-OAEP-3072":
		return "rsaOAEP3072"
	case "ECDH-P256+HKDF":
		return "ecdhP256HKDF"
	}
	return algorithm
}
