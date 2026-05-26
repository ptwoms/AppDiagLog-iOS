// Package pipeline implements the algorithm-agile decrypt flow: pick the right
// AEAD and KEM unwrapper for each envelope based on the strings it carries,
// then assemble plaintext events with session boundary markers injected.
package pipeline

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/appdiaglog/diaglog-decrypt/internal/aead"
	"github.com/appdiaglog/diaglog-decrypt/internal/envelope"
	"github.com/appdiaglog/diaglog-decrypt/internal/kem"
)

// DecryptEnvelope walks an envelope to its event list and injects session
// boundary events (session_start / session_end).
//
// Returns nil when the session has zero events and ended cleanly — those are
// trivially empty sessions (app launched and closed before any flush). Callers
// should skip them rather than writing an empty output file.
func DecryptEnvelope(env envelope.Envelope, keys map[string][]byte) ([]envelope.Event, error) {
	priv, ok := keys[env.Encryption.KeyID]
	if !ok {
		return nil, fmt.Errorf("no private key for key_id %q", env.Encryption.KeyID)
	}

	kemCt, err := base64.StdEncoding.DecodeString(env.Encryption.KemCiphertext)
	if err != nil {
		return nil, fmt.Errorf("kem_ciphertext base64: %w", err)
	}
	wrapped, err := base64.StdEncoding.DecodeString(env.Encryption.WrappedDek)
	if err != nil {
		return nil, fmt.Errorf("wrapped_dek base64: %w", err)
	}
	iv, err := base64.StdEncoding.DecodeString(env.Encryption.Nonce)
	if err != nil {
		return nil, fmt.Errorf("nonce base64: %w", err)
	}
	payload, err := base64.StdEncoding.DecodeString(env.Payload)
	if err != nil {
		return nil, fmt.Errorf("payload base64: %w", err)
	}

	dek, err := kem.UnwrapDEK(env.Encryption.KekAlgorithm, kemCt, wrapped, priv)
	if err != nil {
		return nil, fmt.Errorf("unwrap DEK (%s): %w", env.Encryption.KekAlgorithm, err)
	}
	defer wipe(dek)

	plaintext, err := aead.Decrypt(env.Encryption.Algorithm, dek, iv, payload, env.AAD())
	if err != nil {
		return nil, fmt.Errorf("decrypt payload (%s): %w", env.Encryption.Algorithm, err)
	}

	var events []envelope.Event
	if err := json.Unmarshal(plaintext, &events); err != nil {
		return nil, fmt.Errorf("parse events: %w", err)
	}
	return withBoundaries(env, events), nil
}

// withBoundaries injects session_start and session_end boundary events.
//
// Returns nil for sessions that have zero events and a clean seal — those are
// trivially empty and callers should skip them.
//
// Boundary events get reserved sequence positions around SDK events:
// session_start uses Seq=0, while session_end uses max(raw Seq)+1. SDK events
// start at Seq=1, so read paths can sort by Seq without pushing boundaries
// together at the end of the session.
// Abnormal terminations (force-kill, OOM, watchdog, debugger-intercepted crash)
// are surfaced via session_end level=warning + props["sealed"]="false".
func withBoundaries(env envelope.Envelope, events []envelope.Event) []envelope.Event {
	hasCleanSeal := env.SealedAt != nil

	// Truly empty, cleanly-sealed session — nothing useful to record.
	if len(events) == 0 && hasCleanSeal {
		return nil
	}

	// session_start carries device metadata for immediate context.
	startProps := make(map[string]string, len(env.DeviceMetadata)+1)
	for k, v := range env.DeviceMetadata {
		startProps[k] = v
	}
	if env.SessionTag != nil {
		startProps["session_tag"] = *env.SessionTag
	}
	start := envelope.Event{
		Seq:   0,
		Ts:    env.CreatedAt,
		Event: "session_start",
		Level: "info",
		Props: startProps,
	}

	// Best-effort end timestamp when sealed_at is absent.
	endTs := env.CreatedAt
	if len(events) > 0 {
		endTs = events[len(events)-1].Ts
	} else if hasCleanSeal {
		endTs = *env.SealedAt
	}

	endProps := map[string]string{"event_count": strconv.Itoa(len(events))}
	endSeq := int64(1)
	for _, e := range events {
		if e.Seq >= endSeq {
			endSeq = e.Seq + 1
		}
	}
	var tail []envelope.Event

	if hasCleanSeal {
		tail = []envelope.Event{{
			Seq:   endSeq,
			Ts:    *env.SealedAt,
			Event: "session_end",
			Level: "info",
			Props: endProps,
		}}
	} else {
		endProps["sealed"] = "false"
		tail = []envelope.Event{{
			Seq:   endSeq,
			Ts:    endTs,
			Event: "session_end",
			Level: "warning",
			Props: endProps,
		}}
	}

	result := make([]envelope.Event, 0, 1+len(events)+len(tail))
	result = append(result, start)
	result = append(result, events...)
	result = append(result, tail...)
	return result
}

func wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
