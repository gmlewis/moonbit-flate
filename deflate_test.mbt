// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.1:src/compress/flate/deflate_test.go
// which has the copyright notice:
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

typealias Slice[T] = @io.Slice[T]

type! TestError String derive(Show)

test "writer dict" {
  let dict = Slice::new(b"hello world".to_array())
  let text = Slice::new(b"hello again world".to_array())
  let b = @io.Buffer::new()
  let w = @flate.Writer::new(b)
  guard let (11, None) = w.write(dict)
  // w.flush()
  // b.reset()
  guard let (17, None) = w.write(text)
  guard let None = w.close()
  let want = b.to_bytes()
  assert_eq!(38, want.length())

  //
  let b1 = @io.Buffer::new()
  let w = @flate.Writer::new_dict(b1, dict)
  guard let (17, None) = w.write(text)
  guard let None = w.close()

  //
  let got = b1.to_bytes()
  assert_eq!(38, got.length())
  if got != want {
    raise TestError("writer wrote \{got} want \{want}")
  }
}
