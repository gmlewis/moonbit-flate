// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/deflate_test.go
// which has the copyright notice:
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

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

  //
  let mut i = 0
  for tc in test_cases {
    for first_n in [1, 65534, 65535, 65536, 65537, 131072] {
      i += 1
      tc[0] = first_n
      let buf = @io.Buffer::new()
      let want = @io.Buffer::new()
      let w : @io.WriteCloser = @flate.Writer::new(buf)
      for n in tc {
        let subset = Bytes::new(n)
        subset.blit(0, abcabc, 0, n)
        guard let (_, None) = want.write_bytes(subset)
        guard let (_, None) = w.write(@io.Slice::new(subset.to_array()))
        // if not(flush) {
        // continue
        // }
        // w.flush!()
      }
      let want = want.to_bytes()
      assert_eq!(None, w.close())

      //
      let got = @io.Slice::new([])
      let r : @io.ReadCloser = @flate.Reader::new(buf)
      guard let (_, None) = r.read(got)
      try {
        let got = got.to_bytes()
        assert_eq!(got, want)
      } catch {
        _ => abort("test #\{i} FAILED")
      }
    }
  }
}
