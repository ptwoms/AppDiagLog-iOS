// Package envelope mirrors the on-disk SessionEnvelope JSON format produced
// by the iOS SDKs. Field names are snake_case to match the
// SDK-side serializers.
package envelope

import "encoding/json"

type Envelope struct {
	Version        int               `json:"version"`
	SessionID      string            `json:"session_id"`
	CreatedAt      string            `json:"created_at"`
	SealedAt       *string           `json:"sealed_at,omitempty"`
	EventCount     int               `json:"event_count"`
	SessionTag     *string           `json:"session_tag,omitempty"`
	DeviceMetadata map[string]string `json:"device_metadata"`
	Encryption     Encryption        `json:"encryption"`
	Payload        string            `json:"payload"`
}

type Encryption struct {
	Algorithm     string            `json:"algorithm"`
	Nonce         string            `json:"nonce"`
	KekAlgorithm  string            `json:"kek_algorithm"`
	KeyID         string            `json:"key_id"`
	KemCiphertext string            `json:"kem_ciphertext"`
	WrappedDek    string            `json:"wrapped_dek"`
	KekParams     map[string]string `json:"kek_params,omitempty"`
}

// Event is one parsed entry from the decrypted payload. The SDK serializes the
// payload as a JSON array of these.
type Event struct {
	Seq    int64             `json:"seq"`
	Ts     string            `json:"ts"`
	Screen *string           `json:"screen,omitempty"`
	Event  string            `json:"event"`
	Level  string            `json:"level"`
	Props  map[string]string `json:"props"`
}

// AAD format used by the SDKs: "<session_id>|<key_id>" UTF-8. Backend and
// every CLI must reproduce this byte for byte or GCM/Poly1305 will reject the
// payload.
func (e *Envelope) AAD() []byte {
	return []byte(e.SessionID + "|" + e.Encryption.KeyID)
}

// Marshal the Event slice with stable key ordering. Convenience for callers
// that want to round-trip events to JSON output.
func MarshalEvents(events []Event) ([]byte, error) {
	return json.MarshalIndent(events, "", "  ")
}
