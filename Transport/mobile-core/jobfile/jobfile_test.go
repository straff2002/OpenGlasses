package jobfile

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func must[T any](v T, e error) T {
	if e != nil {
		panic(e)
	}
	return v
}

func refused(t *testing.T, name string, e error, want error) {
	t.Helper()
	if e == nil || !errors.Is(e, want) {
		t.Fatalf("%s: got %v, want %v", name, e, want)
	}
}

// The checked-in fixture is exactly what Fixtures makes. Run with JOBFILE_WRITE_FIXTURES=1 to
// write it.
func TestTheGoldenFixtureIsCurrentAndReadsBack(t *testing.T) {
	for name, want := range must(Fixtures()) {
		path := filepath.Join("..", "..", "..", "Contracts", "fixtures", name)
		if os.Getenv("JOBFILE_WRITE_FIXTURES") == "1" {
			if e := os.WriteFile(path, want, 0644); e != nil {
				t.Fatal(e)
			}
		}
		got, e := os.ReadFile(path)
		if e != nil || string(got) != string(want) {
			t.Fatalf("%s is not what Fixtures makes; regenerate with JOBFILE_WRITE_FIXTURES=1 (%v)", name, e)
		}
		job, id, e := Verify(got, FixtureKey().Public().(ed25519.PublicKey))
		if e != nil || string(job) != FixtureJob || id.JobID != "job-2031" || id.Revision != 2 {
			t.Fatalf("%v %+v", e, id)
		}
	}
}

func TestTheSignatureIsOverTheDomainAndTheExactJobBytes(t *testing.T) {
	key := FixtureKey()
	public := key.Public().(ed25519.PublicKey)
	job := []byte(FixtureJob)
	_, _, e := Verify(must(Sign(job, ed25519.NewKeyFromSeed(make([]byte, 32)))), public)
	refused(t, "another key", e, ErrSignature)
	_, _, e = Verify(must(Seal(job, ed25519.Sign(key, job))), public)
	refused(t, "no domain", e, ErrSignature)
	_, _, e = Verify(must(Seal(job, ed25519.Sign(key, append([]byte("Avenkin.ManagedJob.v1\x00"), job...)))), public)
	refused(t, "another message's domain", e, ErrSignature)
	// The same job laid out differently is other bytes: the signature does not carry over.
	spaced := []byte(strings.Replace(FixtureJob, `{"job_id"`, `{ "job_id"`, 1))
	_, _, e = Verify(must(Seal(spaced, ed25519.Sign(key, SigningInput(job)))), public)
	refused(t, "re-encoded bytes", e, ErrSignature)
	_, _, e = Verify(must(Seal(job, nil)), public)
	refused(t, "unsigned", e, ErrUnsigned)
	if _, id, signed, e := Open(must(Seal(job, nil))); e != nil || signed || id.Revision != 2 {
		t.Fatalf("an unsigned file does not open: %v", e)
	}
}

func TestOnlyAClosedFormatTwoFileWithAnIdentityOpens(t *testing.T) {
	good := string(must(Fixtures())["job-file-v2.ogjob"])
	encode := func(job string) string { return base64.StdEncoding.EncodeToString([]byte(job)) }
	withJob := func(job string) string {
		return `{"format":"openglasses.job","format_version":2,"job":"` + encode(job) + `"}`
	}
	for name, c := range map[string]struct {
		data string
		want error
	}{
		"format 1":                                   {`{"format":"openglasses.job","format_version":1,"job_reference":"FX-1007"}`, ErrVersion},
		"format 3":                                   {strings.Replace(good, `"format_version":2`, `"format_version":3`, 1), ErrVersion},
		"another format":                             {strings.Replace(good, `openglasses.job`, `openglasses.vault`, 1), ErrMalformed},
		"an extra outer member":                      {strings.Replace(good, `{"format"`, `{"note":"x","format"`, 1), ErrFields},
		"a duplicate outer member":                   {strings.Replace(good, `{"format"`, `{"format":"openglasses.job","format"`, 1), ErrMalformed},
		"trailing data":                              {good + "{}", ErrMalformed},
		"a job that is not base64":                   {`{"format":"openglasses.job","format_version":2,"job":"{}"}`, ErrMalformed},
		"a job that is not an object":                {withJob(`[]`), ErrMalformed},
		"no identifier":                              {withJob(`{"revision":1,"job_reference":"FX-1007"}`), ErrFields},
		"an identifier that is a path":               {withJob(`{"job_id":"../1007","revision":1}`), ErrFields},
		"no revision":                                {withJob(`{"job_id":"job-1"}`), ErrFields},
		"revision zero":                              {withJob(`{"job_id":"job-1","revision":0}`), ErrFields},
		"a fractional revision":                      {withJob(`{"job_id":"job-1","revision":1.0}`), ErrFields},
		"a revision in text":                         {withJob(`{"job_id":"job-1","revision":"1"}`), ErrFields},
		"an unknown job member":                      {withJob(`{"job_id":"job-1","revision":1,"start_now":true}`), ErrFields},
		"a duplicate job member":                     {withJob(`{"job_id":"job-1","job_id":"job-2","revision":1}`), ErrMalformed},
		"a member named twice inside the site":       {withJob(`{"job_id":"job-1","revision":1,"site":{"customer":"A","customer":"B"}}`), ErrMalformed},
		"a member named twice inside a machine":      {withJob(`{"job_id":"job-1","revision":1,"equipment":[{"model":"A","model":"B"}]}`), ErrMalformed},
		"a member named twice inside the signature":  {strings.Replace(good, `{"algorithm":"ed25519",`, `{"algorithm":"ed25519","algorithm":"ed25519",`, 1), ErrMalformed},
		"a format-1 signature member inside the job": {withJob(`{"job_id":"job-1","revision":1,"signature":{}}`), ErrFields},
		"nothing":                                    {``, ErrMalformed},
	} {
		_, _, _, e := Open([]byte(c.data))
		refused(t, name, e, c.want)
	}
	if _, e := Seal([]byte(`{"job_id":"job-1","revision":1}`), make([]byte, 10)); e == nil {
		t.Fatal("a short signature was sealed")
	}
	if _, e := Seal([]byte(`{"job_reference":"FX-1007"}`), nil); e == nil {
		t.Fatal("a job with no identity was sealed")
	}
}

func TestAnOlderRevisionNeverReplacesANewerAndTheSameOneTwiceIsOneJob(t *testing.T) {
	read := func(job string) Identity {
		_, id, _, e := Open(must(Seal([]byte(job), nil)))
		if e != nil {
			t.Fatal(e)
		}
		return id
	}
	held := read(`{"job_id":"job-1","revision":2,"notes":"Gate code 4411."}`)
	for name, c := range map[string]struct {
		job  string
		want Relation
	}{
		"the next revision":                   {`{"job_id":"job-1","revision":3}`, Newer},
		"the revision before":                 {`{"job_id":"job-1","revision":1}`, Older},
		"the same file again":                 {`{"job_id":"job-1","revision":2,"notes":"Gate code 4411."}`, Same},
		"another file at the same revision":   {`{"job_id":"job-1","revision":2,"notes":"Gate code 9999."}`, Conflict},
		"the same words laid out another way": {`{"job_id":"job-1", "revision":2,"notes":"Gate code 4411."}`, Conflict},
		"another job":                         {`{"job_id":"job-2","revision":9}`, Unrelated},
	} {
		if got := Relate(held, read(c.job)); got != c.want {
			t.Fatalf("%s: got %d, want %d", name, got, c.want)
		}
	}
}
