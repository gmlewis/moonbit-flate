// This file is based on the Go implementation found here:
// https://cs.opensource.google/go/go/+/refs/tags/go1.23.2:src/io/io.go
// which has the copyright notice:
// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

pub type! IOEOF  derive(Show)

type! IOErrUnexpectedEOF  derive(Show)

/// `IOReader` is similar to Go's `io.Reader` interface.
pub trait IOReader {
  /// ReadByte reads and returns the next byte from the input or
  /// any error encountered. If ReadByte returns an error, no input
  /// byte was consumed, and the returned byte value is undefined.
  read_byte(Self) -> Byte!Error
  /// ReadFull reads exactly len(buf) bytes from r into buf.
  /// It returns the number of bytes copied and an error if fewer bytes were read.
  /// The error is EOF only if no bytes were read.
  /// If an EOF happens after reading some but not all the bytes,
  /// ReadFull returns [ErrUnexpectedEOF].
  /// On return, n == len(buf) if and only if err == nil.
  /// If r returns an error having read at least len(buf) bytes, the error is dropped.
  read_full(Self, ArrayView[Byte]) -> (Int, Error?)
}

pub fn IOReader::from_buffer(buf : @buffer.Buffer) -> IOReader { // doesn't work: BufferIOReader {
  { bytes: buf.to_bytes(), offset: 0 }
}

struct BufferIOReader {
  bytes : Bytes
  mut offset : Int
}

fn read_byte(self : BufferIOReader) -> Byte!Error {
  let remaining = self.bytes.length() - self.offset
  if remaining <= 0 {
    raise IOEOF
  }
  let b = self.bytes[self.offset]
  self.offset += 1
  b
}

fn read_full(self : BufferIOReader, b : ArrayView[Byte]) -> (Int, Error?) {
  let remaining = self.bytes.length() - self.offset
  let n = b.length()
  if remaining < n {
    return (0, Some(IOEOF))
  }
  for i = 0; i < n; i = i + 1 {
    b[i] = self.bytes[self.offset + i]
  }
  self.offset += n
  (n, None)
}

let io_read_buf_size = 1024

pub fn read_all(self : IOReader) -> Bytes!Error {
  let buf = @buffer.new()
  let b = Array::make(io_read_buf_size, b'\x00')
  for {
    let (n, err) = self.read_full(b[:])
    match err {
      Some(IOEOF) => ()
      Some(err) => raise err
      _ => ()
    }
    if n == 0 {
      break
    }
    for i = 0; i < n; i = i + 1 {
      buf.write_byte(b[i])
    }
  }
  buf.to_bytes()
}
