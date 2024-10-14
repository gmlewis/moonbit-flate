/// `IOWriter` is similar to Go's `io.Writer` interface.
pub trait IOWriter {
  write(Self, Slice[Byte]) -> Int!Error
}

pub fn IOWriter::from_buffer(buf : @buffer.Buffer) -> IOWriter {
  { always_false: false, buf }
}

struct BufferIOWriter {
  always_false : Bool
  buf : @buffer.Buffer
}

fn write(self : BufferIOWriter, b : Slice[Byte]) -> Int!Error {
  if self.always_false {
    raise fail!("compiler workaround - must raise something to satisfy trait")
  }
  let n = b.length()
  self.buf.write_bytes(Bytes::from_iter(b.iter()))
  n
}
