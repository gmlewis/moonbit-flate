/// `IOWriter` is similar to Go's `io.Writer` interface.
pub trait IOWriter {
  write(Self, ArrayView[Byte]) -> (Int, Error?)
}

pub fn IOWriter::from_buffer(buf : @buffer.Buffer) -> IOWriter { // doesn't work: BufferIOWriter {
  { buf, }
}

struct BufferIOWriter {
  buf : @buffer.Buffer
}

fn write(self : BufferIOWriter, b : ArrayView[Byte]) -> (Int, Error?) {
  let n = b.length()
  self.buf.write_bytes(Bytes::from_iter(b.iter()))
  (n, None)
}
