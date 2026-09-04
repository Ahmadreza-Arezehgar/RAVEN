//! Platform IPC client: shared length-prefixed JSON I/O, cfg-gated connect.
//!
//! Unix connects a UDS; Windows connects `\\.\pipe\raven-node`. Framing is
//! always [`encode_request`] / [`decode_response`] (`IPC_VERSION=1`).

use std::io::{Read, Write};
use std::path::Path;
use std::time::Duration;

use raven_core::ipc::{
    decode_response, encode_request, ipc_endpoint, IpcEndpoint, IpcRequest, IpcResponse,
    IPC_VERSION,
};

const IPC_IO_TIMEOUT: Duration = Duration::from_secs(10);

/// Ping→Pong over the platform endpoint. Presence only — not ready / send_path.
pub fn ipc_ping(data_dir: &Path) -> Result<IpcResponse, String> {
    ipc_request(data_dir, &IpcRequest::Ping { v: IPC_VERSION })
}

pub fn ipc_daemon_up(data_dir: &Path) -> bool {
    matches!(ipc_ping(data_dir), Ok(IpcResponse::Pong { .. }))
}

pub fn ipc_request(data_dir: &Path, req: &IpcRequest) -> Result<IpcResponse, String> {
    ipc_request_timeout(data_dir, req, IPC_IO_TIMEOUT)
}

pub fn ipc_request_timeout(
    data_dir: &Path,
    req: &IpcRequest,
    timeout: Duration,
) -> Result<IpcResponse, String> {
    let endpoint = ipc_endpoint(data_dir);
    connect_and_transact(&endpoint, req, timeout)
}

fn connect_and_transact(
    endpoint: &IpcEndpoint,
    req: &IpcRequest,
    timeout: Duration,
) -> Result<IpcResponse, String> {
    match endpoint {
        IpcEndpoint::UnixSocket(path) => connect_unix(path, req, timeout),
        IpcEndpoint::NamedPipe(name) => connect_named_pipe(name, req, timeout),
        IpcEndpoint::Unsupported => Err("ipc_transport_missing".into()),
    }
}

#[cfg(unix)]
fn connect_unix(path: &Path, req: &IpcRequest, timeout: Duration) -> Result<IpcResponse, String> {
    use std::os::unix::net::UnixStream;
    let mut stream = UnixStream::connect(path).map_err(|e| e.to_string())?;
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    transact(&mut stream, req)
}

#[cfg(not(unix))]
fn connect_unix(
    _path: &Path,
    _req: &IpcRequest,
    _timeout: Duration,
) -> Result<IpcResponse, String> {
    Err("ipc_transport_missing".into())
}

#[cfg(windows)]
fn connect_named_pipe(
    name: &str,
    req: &IpcRequest,
    _timeout: Duration,
) -> Result<IpcResponse, String> {
    let mut stream =
        open_named_pipe(name).map_err(|e| format!("named pipe connect {name}: {e}"))?;
    transact(&mut stream, req)
}

#[cfg(windows)]
fn open_named_pipe(name: &str) -> std::io::Result<std::fs::File> {
    use std::fs::OpenOptions;
    use std::io::{Error, ErrorKind};
    use std::thread;

    // ERROR_PIPE_BUSY — server is between instances; retry instead of fail-open.
    const ERROR_PIPE_BUSY: i32 = 231;
    const ATTEMPTS: u32 = 40;

    for attempt in 0..ATTEMPTS {
        match OpenOptions::new().read(true).write(true).open(name) {
            Ok(f) => return Ok(f),
            Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY) && attempt + 1 < ATTEMPTS => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(e),
        }
    }
    Err(Error::new(ErrorKind::TimedOut, "named pipe busy"))
}

#[cfg(not(windows))]
fn connect_named_pipe(
    _name: &str,
    _req: &IpcRequest,
    _timeout: Duration,
) -> Result<IpcResponse, String> {
    Err("ipc_transport_missing".into())
}

fn transact<S: Read + Write>(stream: &mut S, req: &IpcRequest) -> Result<IpcResponse, String> {
    let frame = encode_request(req)?;
    stream.write_all(&frame).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())?;
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).map_err(|e| e.to_string())?;
    let n = u32::from_be_bytes(len_buf) as usize;
    if n == 0 || n > raven_core::MAX_IPC_FRAME {
        return Err("IPC_FRAME".into());
    }
    let mut body = vec![0u8; n];
    stream.read_exact(&mut body).map_err(|e| e.to_string())?;
    let mut resp = Vec::with_capacity(4 + n);
    resp.extend_from_slice(&len_buf);
    resp.extend_from_slice(&body);
    decode_response(&resp)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transact_roundtrip_ping_over_memory() {
        use std::io::Cursor;

        struct Pair {
            read: Cursor<Vec<u8>>,
            write: Vec<u8>,
        }
        impl Read for Pair {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                self.read.read(buf)
            }
        }
        impl Write for Pair {
            fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                self.write.write(buf)
            }
            fn flush(&mut self) -> std::io::Result<()> {
                self.write.flush()
            }
        }

        let req = IpcRequest::Ping { v: IPC_VERSION };
        let resp = IpcResponse::Pong { v: IPC_VERSION };
        let resp_frame = raven_core::encode_response(&resp).unwrap();
        let mut pair = Pair {
            read: Cursor::new(resp_frame),
            write: Vec::new(),
        };
        assert_eq!(transact(&mut pair, &req).unwrap(), resp);
        assert_eq!(pair.write, encode_request(&req).unwrap());
    }

    #[test]
    fn unsupported_endpoint_is_transport_missing() {
        let err = connect_and_transact(
            &IpcEndpoint::Unsupported,
            &IpcRequest::Ping { v: IPC_VERSION },
            IPC_IO_TIMEOUT,
        )
        .unwrap_err();
        assert_eq!(err, "ipc_transport_missing");
    }
}
