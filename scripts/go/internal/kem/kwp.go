package kem

import (
	"bytes"
	"crypto/aes"
	"encoding/binary"
	"errors"
	"fmt"
)

var (
	rfc3394IV     = []byte{0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6, 0xa6}
	rfc5649Marker = []byte{0xa6, 0x59, 0x59, 0xa6}
)

// aesKeyUnwrapWithPadding undoes the DEK wrapping produced by iOS AesKwp.swift
// or any RFC 5649-compliant SDK (Android BouncyCastle AESWRAPPAD, etc.).
//
// Two wire formats exist:
//
//   - iOS (AesKwp.swift): CCSymmetricKeyWrap uses RFC 3394 (IV=A6A6A6A6A6A6A6A6).
//     The caller manually prepends [A6 59 59 A6 | len_4be] to the DEK before
//     wrapping. After unwrapping, the recovered integrity value equals the RFC 3394
//     IV, and the plaintext blocks contain the manual header + DEK.
//
//   - True RFC 5649 (Android BC AESWRAPPAD): The AIV [A6 59 59 A6 | MLI_4be] is
//     used as the initial value inside the KW loop. After unwrapping, the recovered
//     integrity value equals that AIV, and the plaintext blocks are the raw DEK
//     (possibly zero-padded to an 8-byte boundary).
//
// Detection: inspect the recovered `a` value after the raw RFC 3394 loop.
func aesKeyUnwrapWithPadding(kek, wrapped []byte) ([]byte, error) {
	if len(kek) != 16 && len(kek) != 24 && len(kek) != 32 {
		return nil, errors.New("AES-KW KEK must be 16/24/32 bytes")
	}
	if len(wrapped)%8 != 0 || len(wrapped) < 16 {
		return nil, errors.New("AES-KW ciphertext must be a multiple of 8 bytes (≥16)")
	}
	block, err := aes.NewCipher(kek)
	if err != nil {
		return nil, err
	}

	// Single-block special case (n == 1): wrap was AES_K(IV || plaintext).
	if len(wrapped) == 16 {
		plain := make([]byte, 16)
		block.Decrypt(plain, wrapped)
		return dispatchUnpad(plain[:8], plain[8:])
	}

	// General RFC 3394 unwrap loop (no integrity check on `a` yet).
	n := len(wrapped)/8 - 1
	a := make([]byte, 8)
	copy(a, wrapped[:8])
	r := make([][]byte, n)
	for i := 0; i < n; i++ {
		r[i] = make([]byte, 8)
		copy(r[i], wrapped[8*(i+1):8*(i+2)])
	}
	buf := make([]byte, 16)
	for j := 5; j >= 0; j-- {
		for i := n; i >= 1; i-- {
			t := uint64(n*j) + uint64(i)
			ta := make([]byte, 8)
			binary.BigEndian.PutUint64(ta, t)
			for k := 0; k < 8; k++ {
				a[k] ^= ta[k]
			}
			copy(buf[:8], a)
			copy(buf[8:], r[i-1])
			out := make([]byte, 16)
			block.Decrypt(out, buf)
			copy(a, out[:8])
			copy(r[i-1], out[8:])
		}
	}

	padded := make([]byte, 8*n)
	for i, ri := range r {
		copy(padded[8*i:], ri)
	}
	return dispatchUnpad(a, padded)
}

// dispatchUnpad extracts the raw DEK from the unwrapped plaintext by inspecting
// the recovered integrity value `a`.
//
//   - a == A6A6A6A6A6A6A6A6 → iOS AesKwp.swift scheme: the plaintext starts
//     with a manually-prepended RFC 5649 header; strip it with [rfc5649Unpad].
//   - a[0:4] == A65959A6 → true RFC 5649 (Android BC AESWRAPPAD): the MLI is
//     in a[4:8] and the plaintext is the zero-padded DEK; trim to MLI length.
func dispatchUnpad(a, plaintext []byte) ([]byte, error) {
	if len(a) != 8 {
		return nil, fmt.Errorf("unexpected integrity value length: %d", len(a))
	}
	if bytes.Equal(a, rfc3394IV) {
		return rfc5649Unpad(plaintext)
	}
	if bytes.Equal(a[:4], rfc5649Marker) {
		mli := binary.BigEndian.Uint32(a[4:8])
		if int(mli) > len(plaintext) {
			return nil, fmt.Errorf("RFC 5649 MLI %d exceeds plaintext length %d", mli, len(plaintext))
		}
		out := make([]byte, mli)
		copy(out, plaintext[:mli])
		return out, nil
	}
	return nil, fmt.Errorf("unexpected AES-KW integrity value: %x", a)
}

// rfc5649Unpad strips the RFC 5649 header that AesKwp.swift manually prepends
// to the plaintext before RFC 3394 wrapping.
// Header layout: [A6 59 59 A6 | original_length_4be].
func rfc5649Unpad(data []byte) ([]byte, error) {
	if len(data) < 8 {
		return nil, fmt.Errorf("data too short (%d B) for RFC 5649 header", len(data))
	}
	if !bytes.Equal(data[:4], rfc5649Marker) {
		return nil, fmt.Errorf("invalid RFC 5649 marker: %02x%02x%02x%02x",
			data[0], data[1], data[2], data[3])
	}
	length := binary.BigEndian.Uint32(data[4:8])
	if int(length) > len(data)-8 {
		return nil, errors.New("RFC 5649 MLI exceeds available data")
	}
	out := make([]byte, length)
	copy(out, data[8:8+length])
	return out, nil
}
