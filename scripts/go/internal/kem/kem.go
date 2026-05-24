// Package kem dispatches asymmetric DEK unwrap based on the envelope's
// `kek_algorithm` string. Each unwrapper undoes whatever the device-side SDK
// did: ML-KEM (decapsulate→AES-KWP), RSA-OAEP (decrypt directly),
// ECDH-P256+HKDF (decap→HKDF→AES-KWP).
package kem

import (
	"crypto/ecdh"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"errors"
	"fmt"
	"io"

	"github.com/cloudflare/circl/kem/mlkem/mlkem512"
	"github.com/cloudflare/circl/kem/mlkem/mlkem768"
	"golang.org/x/crypto/hkdf"
)

func UnwrapDEK(algorithm string, kemCt, wrappedDek, privateKey []byte) ([]byte, error) {
	switch algorithm {
	case "ML-KEM-768":
		return unwrapMlKem768(kemCt, wrappedDek, privateKey)
	case "ML-KEM-512":
		return unwrapMlKem512(kemCt, wrappedDek, privateKey)
	case "RSA-OAEP-3072":
		return unwrapRsaOaep(wrappedDek, privateKey)
	case "ECDH-P256+HKDF":
		return unwrapEcdhP256(kemCt, wrappedDek, privateKey)
	}
	return nil, fmt.Errorf("unsupported KEK algorithm: %q", algorithm)
}

// -- ML-KEM ----------------------------------------------------------------

func unwrapMlKem768(kemCt, wrapped, priv []byte) ([]byte, error) {
	sk, err := mlkem768.Scheme().UnmarshalBinaryPrivateKey(priv)
	if err != nil {
		// PKCS#8 wraps the raw seed/secret-key. The BC encoding the SDK uses is
		// the raw seed; circl accepts the raw form. If the caller supplied the
		// PKCS#8 envelope, strip it down to the inner OCTET STRING.
		if raw, err2 := unwrapPkcs8(priv); err2 == nil {
			sk, err = mlkem768.Scheme().UnmarshalBinaryPrivateKey(raw)
		}
		if err != nil {
			return nil, fmt.Errorf("parse ML-KEM-768 private key: %w", err)
		}
	}
	shared, err := mlkem768.Scheme().Decapsulate(sk, kemCt)
	if err != nil {
		return nil, fmt.Errorf("ML-KEM-768 decapsulate: %w", err)
	}
	return aesKeyUnwrapWithPadding(shared, wrapped)
}

func unwrapMlKem512(kemCt, wrapped, priv []byte) ([]byte, error) {
	sk, err := mlkem512.Scheme().UnmarshalBinaryPrivateKey(priv)
	if err != nil {
		if raw, err2 := unwrapPkcs8(priv); err2 == nil {
			sk, err = mlkem512.Scheme().UnmarshalBinaryPrivateKey(raw)
		}
		if err != nil {
			return nil, fmt.Errorf("parse ML-KEM-512 private key: %w", err)
		}
	}
	shared, err := mlkem512.Scheme().Decapsulate(sk, kemCt)
	if err != nil {
		return nil, fmt.Errorf("ML-KEM-512 decapsulate: %w", err)
	}
	return aesKeyUnwrapWithPadding(shared, wrapped)
}

// unwrapPkcs8 is a best-effort PKCS#8 unwrapper for keys that arrive in the
// BC-encoded format the JVM produces. Returns the inner OCTET STRING bytes.
// If the input isn't PKCS#8 we surface that as an error and let the caller
// try the raw decoding path.
func unwrapPkcs8(der []byte) ([]byte, error) {
	if len(der) < 4 || der[0] != 0x30 {
		return nil, errors.New("not a DER SEQUENCE")
	}
	// We don't need a fully featured parser: pkcs8.PrivateKey ≈
	// SEQUENCE { version INT, algorithm SEQ, privateKey OCTET-STRING }
	// Find the last OCTET STRING.
	// Walk top-level SEQUENCE.
	i := 1 + lengthByteCount(der[1])
	for i < len(der) {
		tag := der[i]
		i++
		length, used, err := readLength(der[i:])
		if err != nil {
			return nil, err
		}
		i += used
		if tag == 0x04 && i+length <= len(der) { // OCTET STRING
			return der[i : i+length], nil
		}
		i += length
	}
	return nil, errors.New("PKCS#8 inner key not found")
}

func lengthByteCount(b byte) int {
	if b < 0x80 {
		return 1
	}
	return 1 + int(b&0x7F)
}

func readLength(b []byte) (length, used int, err error) {
	if len(b) == 0 {
		return 0, 0, errors.New("truncated DER length")
	}
	first := b[0]
	if first < 0x80 {
		return int(first), 1, nil
	}
	n := int(first & 0x7F)
	if 1+n > len(b) {
		return 0, 0, errors.New("truncated DER length bytes")
	}
	length = 0
	for i := 0; i < n; i++ {
		length = (length << 8) | int(b[1+i])
	}
	return length, 1 + n, nil
}

// -- RSA-OAEP --------------------------------------------------------------

func unwrapRsaOaep(wrapped, priv []byte) ([]byte, error) {
	parsed, err := x509.ParsePKCS8PrivateKey(priv)
	if err != nil {
		return nil, fmt.Errorf("parse RSA private key: %w", err)
	}
	rsaKey, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("PKCS#8 key is not RSA")
	}
	return rsa.DecryptOAEP(sha256.New(), nil, rsaKey, wrapped, nil)
}

// -- ECDH-P256+HKDF --------------------------------------------------------

func unwrapEcdhP256(ephemeralPub, wrapped, priv []byte) ([]byte, error) {
	parsed, err := x509.ParsePKCS8PrivateKey(priv)
	if err != nil {
		return nil, fmt.Errorf("parse EC private key: %w", err)
	}
	ecPriv, ok := tryEcdhKey(parsed)
	if !ok {
		return nil, errors.New("PKCS#8 key is not ECDH-P256")
	}
	pub, err := x509.ParsePKIXPublicKey(ephemeralPub)
	if err != nil {
		return nil, fmt.Errorf("parse ephemeral public key: %w", err)
	}
	ecPub, ok := tryEcdhPublicKey(pub)
	if !ok {
		return nil, errors.New("ephemeral key is not ECDH-P256")
	}
	shared, err := ecPriv.ECDH(ecPub)
	if err != nil {
		return nil, fmt.Errorf("ECDH: %w", err)
	}
	r := hkdf.New(sha256.New, shared, ephemeralPub, []byte("AppDiagLog/ECDH-P256+HKDF"))
	kek := make([]byte, 32)
	if _, err := io.ReadFull(r, kek); err != nil {
		return nil, fmt.Errorf("HKDF expand: %w", err)
	}
	defer func() {
		for i := range kek {
			kek[i] = 0
		}
	}()
	return aesKeyUnwrapWithPadding(kek, wrapped)
}

// crypto/ecdh's PrivateKey/PublicKey are accepted directly by the standard
// library. Older code paths may surface *ecdsa keys; we accept either and
// convert.
func tryEcdhKey(parsed any) (*ecdh.PrivateKey, bool) {
	switch k := parsed.(type) {
	case *ecdh.PrivateKey:
		return k, true
	}
	return nil, false
}

func tryEcdhPublicKey(parsed any) (*ecdh.PublicKey, bool) {
	switch k := parsed.(type) {
	case *ecdh.PublicKey:
		return k, true
	}
	return nil, false
}
