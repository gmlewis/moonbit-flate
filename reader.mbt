/// This file is based on the Go implementation found here:
/// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/inflate.go
/// which has the copyright notice:
/// Copyright 2009 The Go Authors. All rights reserved.
/// Use of this source code is governed by a BSD-style
/// license that can be found in the LICENSE file.

pub trait IOReader {
  read(Self, Bytes) -> Int!Error
}

pub trait IOReadCloser {
  read(Self, Bytes) -> Int!Error
  close(Self) -> Unit!Error
}

struct Reader {}

/// Reader::new returns a new ReadCloser that can be used
/// to read the uncompressed version of r.
/// If r does not also implement [io.ByteReader],
/// the decompressor may read more data than necessary from r.
/// The reader returns [io.EOF] after the final block in the DEFLATE stream has
/// been encountered. Any trailing data after the final block is ignored.
///
/// The [io.ReadCloser] returned by Reader::new also implements [Resetter].
pub fn Reader::new(r : IOReader) -> IOReadCloser {
  // fixed_huffman_decoder_init()

  let f = Decompressor::new(r)
  // f.makeReader(r)
  // f.bits = new([maxNumLit + maxNumDist]int)
  // f.codebits = new([numCodes]int)
  // f.step = (*decompressor).nextBlock
  // f.dict.init(max_match_offset, nil)
  f
}
