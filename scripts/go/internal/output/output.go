// Package output writes decrypted events to disk in JSONL (one file per
// session), CSV (combined sessions.csv + events.csv), combined JSONL (all
// events with continuous sequence into combined.jsonl), or XLSX (export.xlsx with
// Sessions and Events sheets) format.
package output

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"github.com/appdiaglog/diaglog-decrypt/internal/envelope"
	"github.com/xuri/excelize/v2"
)

// Writer is closed once at the end of a run.
type Writer interface {
	Write(env envelope.Envelope, events []envelope.Event) error
	Close() error
}

// New picks an implementation by format.
func New(format, outDir string) (Writer, error) {
	switch format {
	case "jsonl", "":
		return &jsonlWriter{outDir: outDir}, nil
	case "csv":
		return openCsvWriter(outDir)
	case "combined":
		return &combinedWriter{outDir: outDir}, nil
	case "xls":
		return &xlsxWriter{outDir: outDir}, nil
	}
	return nil, fmt.Errorf("unsupported --format %q (expected jsonl|csv|combined|xls)", format)
}

// -- jsonl -----------------------------------------------------------------

type jsonlWriter struct {
	outDir string
}

func (j *jsonlWriter) Write(env envelope.Envelope, events []envelope.Event) error {
	path := filepath.Join(j.outDir, env.SessionID+".jsonl")
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetEscapeHTML(false)
	for _, e := range sortedEvents(events) {
		if err := enc.Encode(e); err != nil {
			return err
		}
	}
	return nil
}

func (j *jsonlWriter) Close() error { return nil }

// -- csv -------------------------------------------------------------------

type csvWriter struct {
	sessionsFile *os.File
	eventsFile   *os.File
	sessions     *csv.Writer
	events       *csv.Writer
}

func openCsvWriter(outDir string) (*csvWriter, error) {
	sf, err := os.Create(filepath.Join(outDir, "sessions.csv"))
	if err != nil {
		return nil, err
	}
	ef, err := os.Create(filepath.Join(outDir, "events.csv"))
	if err != nil {
		sf.Close()
		return nil, err
	}
	w := &csvWriter{
		sessionsFile: sf,
		eventsFile:   ef,
		sessions:     csv.NewWriter(sf),
		events:       csv.NewWriter(ef),
	}
	if err := w.sessions.Write([]string{
		"id", "key_id", "created_at", "sealed_at", "event_count",
		"session_tag", "device_metadata",
	}); err != nil {
		w.Close()
		return nil, err
	}
	if err := w.events.Write([]string{
		"session_id", "seq", "ts", "level", "event_name", "screen", "props",
	}); err != nil {
		w.Close()
		return nil, err
	}
	return w, nil
}

func (c *csvWriter) Write(env envelope.Envelope, events []envelope.Event) error {
	meta, _ := json.Marshal(env.DeviceMetadata)
	sealedAt := ""
	if env.SealedAt != nil {
		sealedAt = *env.SealedAt
	}
	tag := ""
	if env.SessionTag != nil {
		tag = *env.SessionTag
	}
	if err := c.sessions.Write([]string{
		env.SessionID,
		env.Encryption.KeyID,
		env.CreatedAt,
		sealedAt,
		strconv.Itoa(env.EventCount),
		tag,
		string(meta),
	}); err != nil {
		return err
	}
	for _, e := range sortedEvents(events) {
		screen := ""
		if e.Screen != nil {
			screen = *e.Screen
		}
		props, _ := json.Marshal(e.Props)
		if err := c.events.Write([]string{
			env.SessionID,
			strconv.FormatInt(e.Seq, 10),
			e.Ts,
			e.Level,
			e.Event,
			screen,
			string(props),
		}); err != nil {
			return err
		}
	}
	return nil
}

func (c *csvWriter) Close() error {
	c.sessions.Flush()
	c.events.Flush()
	return multiErr(c.sessions.Error(), c.events.Error(), c.sessionsFile.Close(), c.eventsFile.Close())
}

func multiErr(errs ...error) error {
	for _, e := range errs {
		if e != nil {
			return e
		}
	}
	return nil
}

// -- combined ---------------------------------------------------------------

// combinedEntry pairs an event with its originating session ID so that the
// combined output file is self-contained.
type combinedEntry struct {
	SessionID        string `json:"session_id"`
	sessionCreatedAt string
	envelope.Event
}

type combinedWriter struct {
	outDir  string
	entries []combinedEntry
}

func (c *combinedWriter) Write(env envelope.Envelope, events []envelope.Event) error {
	for _, e := range events {
		c.entries = append(c.entries, combinedEntry{
			SessionID:        env.SessionID,
			sessionCreatedAt: env.CreatedAt,
			Event:            e,
		})
	}
	return nil
}

// Close walks sessions in creation order, sorts by per-session sequence, and
// writes a continuous combined sequence to combined.jsonl.
func (c *combinedWriter) Close() error {
	sort.Slice(c.entries, func(i, j int) bool {
		if c.entries[i].sessionCreatedAt != c.entries[j].sessionCreatedAt {
			return c.entries[i].sessionCreatedAt < c.entries[j].sessionCreatedAt
		}
		if c.entries[i].SessionID != c.entries[j].SessionID {
			return c.entries[i].SessionID < c.entries[j].SessionID
		}
		if displaySeq(c.entries[i].Seq) != displaySeq(c.entries[j].Seq) {
			return displaySeq(c.entries[i].Seq) < displaySeq(c.entries[j].Seq)
		}
		return c.entries[i].Ts < c.entries[j].Ts
	})
	if err := os.MkdirAll(c.outDir, 0o755); err != nil {
		return err
	}
	f, err := os.Create(filepath.Join(c.outDir, "combined.jsonl"))
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetEscapeHTML(false)
	for i, e := range c.entries {
		e.Seq = int64(i + 1)
		if err := enc.Encode(e); err != nil {
			return err
		}
	}
	return nil
}

// -- xlsx -------------------------------------------------------------------

var (
	sessionsHeaders = []string{"id", "key_id", "created_at", "sealed_at", "event_count",
		"session_tag", "device_metadata"}
	eventsHeaders = []string{"session_id", "seq", "ts", "level", "event_name", "screen", "props"}
)

type xlsxEventRow struct {
	sessionID        string
	sessionCreatedAt string
	seq              int64
	ts               string
	level            string
	eventName        string
	screen           string
	props            string
}

type xlsxWriter struct {
	outDir      string
	sessionRows [][]string
	eventRows   []xlsxEventRow
}

func (x *xlsxWriter) Write(env envelope.Envelope, events []envelope.Event) error {
	meta, _ := json.Marshal(env.DeviceMetadata)
	sealedAt := ""
	if env.SealedAt != nil {
		sealedAt = *env.SealedAt
	}
	tag := ""
	if env.SessionTag != nil {
		tag = *env.SessionTag
	}
	x.sessionRows = append(x.sessionRows, []string{
		env.SessionID,
		env.Encryption.KeyID,
		env.CreatedAt,
		sealedAt,
		strconv.Itoa(env.EventCount),
		tag,
		string(meta),
	})
	for _, e := range events {
		screen := ""
		if e.Screen != nil {
			screen = *e.Screen
		}
		props, _ := json.Marshal(e.Props)
		x.eventRows = append(x.eventRows, xlsxEventRow{
			sessionID:        env.SessionID,
			sessionCreatedAt: env.CreatedAt,
			seq:              e.Seq,
			ts:               e.Ts,
			level:            e.Level,
			eventName:        e.Event,
			screen:           screen,
			props:            string(props),
		})
	}
	return nil
}

// Close sorts event rows by session creation time and SDK per-session sequence,
// then writes a continuous combined sequence to export.xlsx.
func (x *xlsxWriter) Close() error {
	sort.Slice(x.eventRows, func(i, j int) bool {
		if x.eventRows[i].sessionCreatedAt != x.eventRows[j].sessionCreatedAt {
			return x.eventRows[i].sessionCreatedAt < x.eventRows[j].sessionCreatedAt
		}
		if x.eventRows[i].sessionID != x.eventRows[j].sessionID {
			return x.eventRows[i].sessionID < x.eventRows[j].sessionID
		}
		if displaySeq(x.eventRows[i].seq) != displaySeq(x.eventRows[j].seq) {
			return displaySeq(x.eventRows[i].seq) < displaySeq(x.eventRows[j].seq)
		}
		return x.eventRows[i].ts < x.eventRows[j].ts
	})
	if err := os.MkdirAll(x.outDir, 0o755); err != nil {
		return err
	}

	f := excelize.NewFile()
	defer f.Close()

	// -- Sessions sheet -------------------------------------------------------
	const sheetSessions = "Sessions"
	f.SetSheetName("Sheet1", sheetSessions)
	if err := writeXlsxHeader(f, sheetSessions, sessionsHeaders); err != nil {
		return err
	}
	for i, row := range x.sessionRows {
		cell, _ := excelize.CoordinatesToCellName(1, i+2)
		if err := f.SetSheetRow(sheetSessions, cell, &row); err != nil {
			return err
		}
	}

	// -- Events sheet ---------------------------------------------------------
	const sheetEvents = "Events"
	if _, err := f.NewSheet(sheetEvents); err != nil {
		return err
	}
	if err := writeXlsxHeader(f, sheetEvents, eventsHeaders); err != nil {
		return err
	}
	for i, r := range x.eventRows {
		cell, _ := excelize.CoordinatesToCellName(1, i+2)
		row := []interface{}{r.sessionID, int64(i + 1), r.ts, r.level, r.eventName, r.screen, r.props}
		if err := f.SetSheetRow(sheetEvents, cell, &row); err != nil {
			return err
		}
	}

	return f.SaveAs(filepath.Join(x.outDir, "export.xlsx"))
}

func writeXlsxHeader(f *excelize.File, sheet string, headers []string) error {
	style, err := f.NewStyle(&excelize.Style{Font: &excelize.Font{Bold: true}})
	if err != nil {
		return err
	}
	for col, h := range headers {
		cell, _ := excelize.CoordinatesToCellName(col+1, 1)
		if err := f.SetCellValue(sheet, cell, h); err != nil {
			return err
		}
		if err := f.SetCellStyle(sheet, cell, cell, style); err != nil {
			return err
		}
	}
	return nil
}

func sortedEvents(events []envelope.Event) []envelope.Event {
	out := append([]envelope.Event(nil), events...)
	sort.Slice(out, func(i, j int) bool {
		if displaySeq(out[i].Seq) != displaySeq(out[j].Seq) {
			return displaySeq(out[i].Seq) < displaySeq(out[j].Seq)
		}
		return out[i].Ts < out[j].Ts
	})
	return out
}

func displaySeq(seq int64) int64 {
	if seq < 0 {
		return 1<<63 - 1
	}
	return seq
}

// satisfy io import for tooling consistency (unused once we go past Goimports).
var _ io.Writer = (*os.File)(nil)
