/// `IOReader` is similar to Go's `io.Reader` interface.
pub trait IOReader {
  read(Self, Bytes) -> Int!Error
}

pub fn IOReader::from_buffer(buf : Buffer) -> IOReader {
  { bytes: buf.to_bytes(), offset: 0 }
}

struct BufferIOReader {
  bytes : Bytes
  mut offset : Int
}

fn read(self : BufferIOReader, b : Bytes) -> Int!Error {
  let remaining = self.bytes.length() - self.offset
  if remaining <= 0 {
    raise IOEOF
  }
  let n = b.length()
  if n <= remaining {
    b.blit(0, self.bytes, self.offset, remaining)
    self.offset += remaining
    return remaining
  }
  b.blit(0, self.bytes, self.offset, n)
  self.offset += n
  return n
}
