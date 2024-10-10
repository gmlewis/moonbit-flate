/// This file is based on the Go implementation found here:
/// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/deflate_test.go
/// which has the copyright notice:
/// Copyright 2009 The Go Authors. All rights reserved.
/// Use of this source code is governed by a BSD-style
/// license that can be found in the LICENSE file.

// TestBestSpeed tests that round-tripping through deflate and then inflate
// recovers the original input. The Write sizes are near the thresholds in the
// compressor.encSpeed method (0, 16, 128), as well as near maxStoreBlockSize
// (65535).
test "TestBestSpeed" {
  let abc_len = 128
  let abc = Bytes::make(abc_len, b'\x00')
  for i = 0; i < abc_len; i = i + 1 {
    abc[i] = i.to_byte()
  }
  let num_copies = 131072 / abc_len
  let abcabc = Bytes::new(abc_len * num_copies)
  for i = 0; i < num_copies; i = i + 1 {
    blit(abcabc, i * abc_len, abc, 0, abc_len)
  }

  //
  let test_cases = [
    [65536, 0],
    [65536, 1],
    [65536, 1, 256],
    [65536, 1, 65536],
    [65536, 14],
    [65536, 15],
    [65536, 16],
    [65536, 16, 256],
    [65536, 16, 65536],
    [65536, 127],
    [65536, 128],
    [65536, 128, 256],
    [65536, 128, 65536],
    [65536, 129],
    [65536, 65536, 256],
    [65536, 65536, 65536],
  ]
  let broken = { 0: false, 4: true }

  //
  let mut i = 0
  for tc in test_cases {
    for first_n in [1, 65534, 65535, 65536, 65537, 131072] {
      i += 1
      @flate.gml_debug.val = broken[i].or_default()
      tc[0] = first_n
      println("\nRunning test #\{i}: tc=\{dump_arr(tc)}, first_n=\{first_n}")
      let buf = Buffer::new()
      let want = Buffer::new()
      let w = @flate.Writer::new(buf)
      for n in tc {
        let subset = Bytes::new(n)
        subset.blit(0, abcabc, 0, n)
        want.write_bytes(subset)
        // gmldbg("w.write!: subset=\{@flate.dump_bytes(subset)}")
        let _ = w.write!(subset)
        // if not(flush) {
        // continue
        // }
        // w.flush!()
      }
      let want = want.to_bytes()
      // gmldbg("want (\{want.length()} bytes)") // "=\{@flate.dump_bytes(want)}")
      w.close!()

      //
      let dump = dump_buffer(buf).to_string().replace_all(old=",", new="")
      @flate.gmldbg("NewReader: buf=\{dump}")
      let r = @flate.Reader::new(@flate.IOReader::from_buffer(buf))
      let got = r.to_bytes!()
      let dump = @flate.dump_bytes(got).to_string().replace_all(old=",", new="")
      try {
        assert_eq!(got, want)
        println("test #\{i} PASSED")
      } catch {
        _ => {
          @flate.gmldbg("got (\{got.length()} bytes)=\{dump}")
          abort("test #\{i} FAILED")
        }
      }
    }
  }
}

fn dump_arr(buf : Array[Int]) -> String {
  buf.to_string().replace_all(old=",", new="")
}

fn dump_buffer(buf : Buffer) -> Array[Int] {
  buf.to_bytes().to_array().map(fn(b) { b.to_int() })
}

// var errIO = errors.New("IO error")

// // failWriter fails with errIO exactly at the nth call to Write.
// type failWriter struct{ n int }

// func (w *failWriter) Write(b Bytes) (int, error) {
// 	w.n--
// 	if w.n == -1 {
// 		return 0, errIO
// 	}
// 	return len(b), nil
// }

// func TestWriterPersistentWriteError(t *testing.T) {
// 	t.Parallel()
// 	d, err := os.ReadFile("../../testdata/Isaac.Newton-Opticks.txt")
// 	if err != nil {
// 		t.Fatalf("ReadFile: %v", err)
// 	}
// 	d = d[:10000] // Keep this test short

// 	zw, err := NewWriter(nil, DefaultCompression)
// 	if err != nil {
// 		t.Fatalf("NewWriter: %v", err)
// 	}

// 	// Sweep over the threshold at which an error is returned.
// 	// The variable i makes it such that the ith call to failWriter.Write will
// 	// return errIO. Since failWriter errors are not persistent, we must ensure
// 	// that flate.Writer errors are persistent.
// 	for i := 0; i < 1000; i++ {
// 		fw := &failWriter{i}
// 		zw.Reset(fw)

// 		_, werr := zw.Write(d)
// 		cerr := zw.Close()
// 		ferr := zw.Flush()
// 		if werr != errIO && werr != nil {
// 			t.Errorf("test %d, mismatching Write error: got %v, want %v", i, werr, errIO)
// 		}
// 		if cerr != errIO && fw.n < 0 {
// 			t.Errorf("test %d, mismatching Close error: got %v, want %v", i, cerr, errIO)
// 		}
// 		if ferr != errIO && fw.n < 0 {
// 			t.Errorf("test %d, mismatching Flush error: got %v, want %v", i, ferr, errIO)
// 		}
// 		if fw.n >= 0 {
// 			// At this point, the failure threshold was sufficiently high enough
// 			// that we wrote the whole stream without any errors.
// 			return
// 		}
// 	}
// }
// func TestWriterPersistentFlushError(t *testing.T) {
// 	zw, err := NewWriter(&failWriter{0], DefaultCompression)
// 	if err != nil {
// 		t.Fatalf("NewWriter: %v", err)
// 	}
// 	flushErr := zw.Flush()
// 	closeErr := zw.Close()
// 	_, writeErr := zw.Write(Bytes("Test"))
// 	checkErrors([]error{closeErr, flushErr, writeErr], errIO, t)
// }

// func TestWriterPersistentCloseError(t *testing.T) {
// 	// If underlying writer return error on closing stream we should persistent this error across all writer calls.
// 	zw, err := NewWriter(&failWriter{0], DefaultCompression)
// 	if err != nil {
// 		t.Fatalf("NewWriter: %v", err)
// 	}
// 	closeErr := zw.Close()
// 	flushErr := zw.Flush()
// 	_, writeErr := zw.Write(Bytes("Test"))
// 	checkErrors([]error{closeErr, flushErr, writeErr], errIO, t)

// 	// After closing writer we should persistent "write after close" error across Flush and Write calls, but return nil
// 	// on next Close calls.
// 	var b bytes.Buffer
// 	zw.Reset(&b)
// 	err = zw.Close()
// 	if err != nil {
// 		t.Fatalf("First call to close returned error: %s", err)
// 	}
// 	err = zw.Close()
// 	if err != nil {
// 		t.Fatalf("Second call to close returned error: %s", err)
// 	}

// 	flushErr = zw.Flush()
// 	_, writeErr = zw.Write(Bytes("Test"))
// 	checkErrors([]error{flushErr, writeErr], errWriterClosed, t)
// }

// func checkErrors(got []error, want error, t *testing.T) {
// 	t.Helper()
// 	for _, err := range got {
// 		if err != want {
// 			t.Errorf("Error doesn't match\nWant: %s\nGot: %s", want, got)
// 		}
// 	}
// }

// func TestBestSpeedMatch(t *testing.T) {
// 	t.Parallel()
// 	cases := []struct {
// 		previous, current Bytes
// 		t, s, want        int32
// 	}{{
// 		previous: [0, 0, 0, 1, 2},
// 		current:  [3, 4, 5, 0, 1, 2, 3, 4, 5},
// 		t:        -3,
// 		s:        3,
// 		want:     6,
// 	], {
// 		previous: [0, 0, 0, 1, 2},
// 		current:  [2, 4, 5, 0, 1, 2, 3, 4, 5},
// 		t:        -3,
// 		s:        3,
// 		want:     3,
// 	], {
// 		previous: [0, 0, 0, 1, 1},
// 		current:  [3, 4, 5, 0, 1, 2, 3, 4, 5},
// 		t:        -3,
// 		s:        3,
// 		want:     2,
// 	], {
// 		previous: [0, 0, 0, 1, 2},
// 		current:  [2, 2, 2, 2, 1, 2, 3, 4, 5},
// 		t:        -1,
// 		s:        0,
// 		want:     4,
// 	], {
// 		previous: [0, 0, 0, 1, 2, 3, 4, 5, 2, 2},
// 		current:  [2, 2, 2, 2, 1, 2, 3, 4, 5},
// 		t:        -7,
// 		s:        4,
// 		want:     5,
// 	], {
// 		previous: [9, 9, 9, 9, 9},
// 		current:  [2, 2, 2, 2, 1, 2, 3, 4, 5},
// 		t:        -1,
// 		s:        0,
// 		want:     0,
// 	], {
// 		previous: [9, 9, 9, 9, 9},
// 		current:  [9, 2, 2, 2, 1, 2, 3, 4, 5},
// 		t:        0,
// 		s:        1,
// 		want:     0,
// 	], {
// 		previous: [},
// 		current:  [9, 2, 2, 2, 1, 2, 3, 4, 5},
// 		t:        -5,
// 		s:        1,
// 		want:     0,
// 	], {
// 		previous: [},
// 		current:  [9, 2, 2, 2, 1, 2, 3, 4, 5},
// 		t:        -1,
// 		s:        1,
// 		want:     0,
// 	], {
// 		previous: [},
// 		current:  [2, 2, 2, 2, 1, 2, 3, 4, 5},
// 		t:        0,
// 		s:        1,
// 		want:     3,
// 	], {
// 		previous: [3, 4, 5},
// 		current:  [3, 4, 5},
// 		t:        -3,
// 		s:        0,
// 		want:     3,
// 	], {
// 		previous: make(Bytes, 1000),
// 		current:  make(Bytes, 1000),
// 		t:        -1000,
// 		s:        0,
// 		want:     maxMatchLength - 4,
// 	], {
// 		previous: make(Bytes, 200),
// 		current:  make(Bytes, 500),
// 		t:        -200,
// 		s:        0,
// 		want:     maxMatchLength - 4,
// 	], {
// 		previous: make(Bytes, 200),
// 		current:  make(Bytes, 500),
// 		t:        0,
// 		s:        1,
// 		want:     maxMatchLength - 4,
// 	], {
// 		previous: make(Bytes, maxMatchLength-4),
// 		current:  make(Bytes, 500),
// 		t:        -(maxMatchLength - 4),
// 		s:        0,
// 		want:     maxMatchLength - 4,
// 	], {
// 		previous: make(Bytes, 200),
// 		current:  make(Bytes, 500),
// 		t:        -200,
// 		s:        400,
// 		want:     100,
// 	], {
// 		previous: make(Bytes, 10),
// 		current:  make(Bytes, 500),
// 		t:        200,
// 		s:        400,
// 		want:     100,
// 	}}
// 	for i, c := range cases {
// 		e := deflateFast{prev: c.previous}
// 		got := e.matchLen(c.s, c.t, c.current)
// 		if got != c.want {
// 			t.Errorf("Test %d: match length, want %d, got %d", i, c.want, got)
// 		}
// 	}
// }

// func TestBestSpeedMaxMatchOffset(t *testing.T) {
// 	t.Parallel()
// 	const abc, xyz = "abcdefgh", "stuvwxyz"
// 	for _, matchBefore := range []bool{false, true} {
// 		for _, extra := range []int{0, inputMargin - 1, inputMargin, inputMargin + 1, 2 * inputMargin} {
// 			for offsetAdj := -5; offsetAdj <= +5; offsetAdj++ {
// 				report := func(desc string, err error) {
// 					t.Errorf("matchBefore=%t, extra=%d, offsetAdj=%d: %s%v",
// 						matchBefore, extra, offsetAdj, desc, err)
// 				}

// 				offset := maxMatchOffset + offsetAdj

// 				// Make src to be a Bytes of the form
// 				//	"%s%s%s%s%s" % (abc, zeros0, xyzMaybe, abc, zeros1)
// 				// where:
// 				//	zeros0 is approximately maxMatchOffset zeros.
// 				//	xyzMaybe is either xyz or the empty string.
// 				//	zeros1 is between 0 and 30 zeros.
// 				// The difference between the two abc's will be offset, which
// 				// is maxMatchOffset plus or minus a small adjustment.
// 				src := make(Bytes, offset+len(abc)+extra)
// 				copy(src, abc)
// 				if !matchBefore {
// 					copy(src[offset-len(xyz):], xyz)
// 				}
// 				copy(src[offset:], abc)

// 				buf := new(bytes.Buffer)
// 				w, err := NewWriter(buf, BestSpeed)
// 				if err != nil {
// 					report("NewWriter: ", err)
// 					continue
// 				}
// 				if _, err := w.Write(src); err != nil {
// 					report("Write: ", err)
// 					continue
// 				}
// 				if err := w.Close(); err != nil {
// 					report("Writer.Close: ", err)
// 					continue
// 				}

// 				r := NewReader(buf)
// 				dst, err := io.ReadAll(r)
// 				r.Close()
// 				if err != nil {
// 					report("ReadAll: ", err)
// 					continue
// 				}

// 				if !bytes.Equal(dst, src) {
// 					report("", fmt.Errorf("bytes differ after round-tripping"))
// 					continue
// 				}
// 			}
// 		}
// 	}
// }

// func TestBestSpeedShiftOffsets(t *testing.T) {
// 	// Test if shiftoffsets properly preserves matches and resets out-of-range matches
// 	// seen in https://github.com/golang/go/issues/4142
// 	enc := newDeflateFast()

// 	// testData may not generate internal matches.
// 	testData := make(Bytes, 32)
// 	rng := rand.New(rand.NewSource(0))
// 	for i := range testData {
// 		testData[i] = byte(rng.Uint32())
// 	}

// 	// Encode the testdata with clean state.
// 	// Second part should pick up matches from the first block.
// 	wantFirstTokens := len(enc.encode(nil, testData))
// 	wantSecondTokens := len(enc.encode(nil, testData))

// 	if wantFirstTokens <= wantSecondTokens {
// 		t.Fatalf("test needs matches between inputs to be generated")
// 	}
// 	// Forward the current indicator to before wraparound.
// 	enc.cur = bufferReset - int32(len(testData))

// 	// Part 1 before wrap, should match clean state.
// 	got := len(enc.encode(nil, testData))
// 	if wantFirstTokens != got {
// 		t.Errorf("got %d, want %d tokens", got, wantFirstTokens)
// 	}

// 	// Verify we are about to wrap.
// 	if enc.cur != bufferReset {
// 		t.Errorf("got %d, want e.cur to be at bufferReset (%d)", enc.cur, bufferReset)
// 	}

// 	// Part 2 should match clean state as well even if wrapped.
// 	got = len(enc.encode(nil, testData))
// 	if wantSecondTokens != got {
// 		t.Errorf("got %d, want %d token", got, wantSecondTokens)
// 	}

// 	// Verify that we wrapped.
// 	if enc.cur >= bufferReset {
// 		t.Errorf("want e.cur to be < bufferReset (%d), got %d", bufferReset, enc.cur)
// 	}

// 	// Forward the current buffer, leaving the matches at the bottom.
// 	enc.cur = bufferReset
// 	enc.shiftOffsets()

// 	// Ensure that no matches were picked up.
// 	got = len(enc.encode(nil, testData))
// 	if wantFirstTokens != got {
// 		t.Errorf("got %d, want %d tokens", got, wantFirstTokens)
// 	}
// }

// func TestMaxStackSize(t *testing.T) {
// 	// This test must not run in parallel with other tests as debug.SetMaxStack
// 	// affects all goroutines.
// 	n := debug.SetMaxStack(1 << 16)
// 	defer debug.SetMaxStack(n)

// 	var wg sync.WaitGroup
// 	defer wg.Wait()

// 	b := make(Bytes, 1<<20)
// 	for level := HuffmanOnly; level <= BestCompression; level++ {
// 		// Run in separate goroutine to increase probability of stack regrowth.
// 		wg.Add(1)
// 		go func(level int) {
// 			defer wg.Done()
// 			zw, err := NewWriter(io.Discard, level)
// 			if err != nil {
// 				t.Errorf("level %d, NewWriter() = %v, want nil", level, err)
// 			}
// 			if n, err := zw.Write(b); n != len(b) || err != nil {
// 				t.Errorf("level %d, Write() = (%d, %v), want (%d, nil)", level, n, err, len(b))
// 			}
// 			if err := zw.Close(); err != nil {
// 				t.Errorf("level %d, Close() = %v, want nil", level, err)
// 			}
// 			zw.Reset(io.Discard)
// 		}(level)
// 	}
// }
