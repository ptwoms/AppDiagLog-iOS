// Package aead dispatches symmetric AEAD decryption based on the envelope's
// algorithm string. Tags are appended to ciphertexts in the on-disk format
// (`ciphertext || tag`) — the underlying Go libraries expect that layout for
// AES-GCM and ChaCha20-Poly1305, so no slicing is needed.
package aead

import (
	"crypto/aes"
	"crypto/cipher"
	"fmt"

	"golang.org/x/crypto/chacha20poly1305"
)

func Decrypt(algorithm string, dek, iv, ciphertextWithTag, aad []byte) ([]byte, error) {
	switch algorithm {
	case "AES-256-GCM":
		if len(dek) != 32 {
			return nil, fmt.Errorf("AES-256-GCM needs 32-byte key (got %d)", len(dek))
		}
		return aesGcmOpen(dek, iv, ciphertextWithTag, aad)
	case "AES-128-GCM":
		if len(dek) != 16 {
			return nil, fmt.Errorf("AES-128-GCM needs 16-byte key (got %d)", len(dek))
		}
		return aesGcmOpen(dek, iv, ciphertextWithTag, aad)
	case "ChaCha20-Poly1305":
		if len(dek) != 32 {
			return nil, fmt.Errorf("ChaCha20-Poly1305 needs 32-byte key (got %d)", len(dek))
		}
		ch, err := chacha20poly1305.New(dek)
		if err != nil {
			return nil, err
		}
		return ch.Open(nil, iv, ciphertextWithTag, aad)
	}
	return nil, fmt.Errorf("unsupported symmetric algorithm: %q", algorithm)
}

func aesGcmOpen(key, iv, ciphertextWithTag, aad []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(iv) != gcm.NonceSize() {
		return nil, fmt.Errorf("expected %d-byte nonce, got %d", gcm.NonceSize(), len(iv))
	}
	return gcm.Open(nil, iv, ciphertextWithTag, aad)
}
