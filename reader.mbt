// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/inflate.go
// which has the copyright notice:
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

struct Reader {
  d : IOReadCloser
}

/// `Reader::new` returns a new Reader that can be used
/// to read the uncompressed version of r.
pub fn Reader::new(r : IOReader) -> Reader {
  let d = Decompressor::new(r)
  { d, }
}

/// `to_bytes` reads the uncompressed data from the Reader.
pub fn to_bytes(self : Reader) -> Bytes!Error {
  self.d.to_bytes!()
}

/// `close` enables `Reader` to implement `IOReadCloser`.
pub fn close(self : Reader) -> Unit!Error {
  self.d.close!()
}
