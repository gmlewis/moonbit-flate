/// `IOReadCloser` is similar to Go's `io.ReadCloser`.
pub trait IOReadCloser {
  read(Self, Bytes) -> Int!Error
  close(Self) -> Unit!Error
}

pub fn to_iter(self : IOReadCloser) -> Iter[Byte] {
  let buf = Bytes::new(1)
  Iter::new(
    fn(yield) {
      for {
        try {
          let n = self.read!(buf)
          if n == 0 || yield(buf[0]) == IterEnd {
            break IterEnd
          }
        } catch {
          IOEOF => {
            try {
              self.close!()
            } catch {
              _ => () // TODO: Handle close error here
            }
            return IterEnd
          }
          _ => () // TODO: Handle other error here
        }
      } else {
        IterContinue
      }
    },
  )
}
