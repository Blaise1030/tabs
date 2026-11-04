//! The WebSocket a browser tab attaches to a running shell through.

use super::{Event, Output, Session, pty};
use crate::{AppState, error::BoxError};
use axum::{
    body::Bytes,
    extract::{
        Query, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use futures_util::{SinkExt, StreamExt};
use portable_pty::PtySize;
use std::collections::HashMap;
use tokio::sync::broadcast;

pub(super) async fn ws_handler(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
    State(st): State<AppState>,
) -> Response {
    // Browsers let any site open a WebSocket to localhost and always send
    // Origin when they do; `guard` has checked loopback + token. Without an
    // Origin this isn't a browser we can vouch for.
    if !headers.contains_key(header::ORIGIN) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let id = params.get("id").cloned().unwrap_or_default();
    let resume = params.get("resume").and_then(|v| resume_param(v));
    let session = match pty::open(st, id.clone()).await {
        Ok(Some(s)) => s,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            eprintln!("failed to start session {id}: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    ws.on_upgrade(move |socket| async move {
        if let Err(e) = attach(socket, &session, resume).await {
            eprintln!("session {id} error: {e}");
        }
    })
}

/// What a client attaching gets: the history to replay, and the live output
/// that follows it with nothing missed or repeated. A client that kept its
/// screen gets, as `resumed` history, only the bytes it missed.
struct Replay {
    history: Vec<u8>,
    resumed: bool,
    epoch: String,
    /// The output's byte count where the history ends.
    at: u64,
    exited: bool,
    rx: broadcast::Receiver<Event>,
}

/// `resume=<epoch>:<offset>`: the count a page has seen of an output.
fn resume_param(v: &str) -> Option<(String, u64)> {
    let (epoch, at) = v.split_once(':')?;
    Some((epoch.to_owned(), at.parse().ok()?))
}

impl Output {
    /// Taken under the `output` lock, which the shell's reader also needs
    /// for every chunk, so it only copies. A resume is honoured only within
    /// the same count and while its bytes are still in the scrollback.
    fn replay(&self, resume: Option<(&str, u64)>) -> Replay {
        let start = self.total - self.scrollback.len() as u64;
        let from = resume
            .filter(|&(epoch, at)| epoch == self.epoch && (start..=self.total).contains(&at))
            .map(|(_, at)| at);
        let history = match from {
            Some(at) => self.scrollback_from((at - start) as usize),
            None => {
                let mut history = self.trimmed_modes.replay_prefix();
                history.extend_from_slice(&self.scrollback_bytes());
                history
            }
        };
        Replay {
            history,
            resumed: from.is_some(),
            epoch: self.epoch.clone(),
            at: self.total,
            exited: self.exited,
            rx: self.tx.subscribe(),
        }
    }
}

async fn attach(
    socket: WebSocket,
    session: &Session,
    resume: Option<(String, u64)>,
) -> Result<(), BoxError> {
    let (mut sink, mut stream) = socket.split();

    // The lock is let go before anything is sent: a slow client never
    // holds up the shell's output.
    let Replay {
        history,
        resumed,
        epoch,
        at,
        exited,
        mut rx,
    } = session
        .output
        .lock()
        .unwrap()
        .replay(resume.as_ref().map(|(e, at)| (e.as_str(), *at)));
    // Before the history, so the page knows whether to clear its screen,
    // and the count to resume from next time.
    let info = serde_json::json!({ "epoch": epoch, "at": at, "resumed": resumed });
    let frame = serde_json::json!({ "stream": info }).to_string();
    sink.send(Message::Text(frame.into())).await?;
    // Always sent, even empty: the page treats the first binary message as
    // replayed history (e.g. to skip old bells in it).
    sink.send(Message::Binary(history.into())).await?;
    if exited {
        sink.send(Message::Text(r#"{"exit":true}"#.into())).await?;
        return Ok(());
    }

    let mut pending: Option<BatchEnd> = None;
    loop {
        // A control event that ended the last batch is handled before more
        // output, so a bell, exit or restart stays in order with its bytes.
        if let Some(end) = pending.take() {
            match end {
                BatchEnd::Lagged => break,
                BatchEnd::Bell => sink.send(Message::Text(r#"{"bell":true}"#.into())).await?,
                BatchEnd::Restart => {
                    sink.send(Message::Text(r#"{"restart":true}"#.into()))
                        .await?;
                    break;
                }
                BatchEnd::Exit => {
                    sink.send(Message::Text(r#"{"exit":true}"#.into())).await?;
                    break;
                }
            }
            continue;
        }

        tokio::select! {
            ev = rx.recv() => match ev {
                Ok(Event::Output(first)) => {
                    // A burst arrives as one frame, not one frame per read.
                    let (batch, end) = batch_output(first, &mut rx);
                    sink.send(Message::Binary(batch)).await?;
                    pending = end;
                }
                Ok(Event::Bell) => sink.send(Message::Text(r#"{"bell":true}"#.into())).await?,
                // The daemon replaced this shell (its card's first prompt
                // changed): the tab reattaches to the replacement.
                Ok(Event::Restart) => {
                    sink.send(Message::Text(r#"{"restart":true}"#.into())).await?;
                    break;
                }
                Ok(Event::Exit) | Err(broadcast::error::RecvError::Closed) => {
                    sink.send(Message::Text(r#"{"exit":true}"#.into())).await?;
                    break;
                }
                // This client fell too far behind to stay consistent; drop it
                // and let it reconnect, which replays the scrollback cleanly.
                Err(broadcast::error::RecvError::Lagged(_)) => break,
            },
            msg = stream.next() => match msg {
                Some(Ok(Message::Binary(data))) => session.input.send(data)?,
                Some(Ok(Message::Text(text))) => match control(&text) {
                    Control::Resize { cols, rows } => {
                        let _ = session.master.lock().unwrap().resize(PtySize {
                            rows,
                            cols,
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                    Control::Reply(reply) => sink.send(Message::Text(reply.into())).await?,
                    Control::Ignore => {}
                },
                // The browser went away; the shell keeps running for a reattach.
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
        }
    }

    let _ = sink.close().await;
    Ok(())
}

/// How much output one WebSocket frame carries before the next one.
const MAX_FRAME: usize = 64 * 1024;

/// A control event that ended a batch, or a lag that must drop the socket.
#[derive(Debug, PartialEq, Eq)]
enum BatchEnd {
    Bell,
    Exit,
    Restart,
    Lagged,
}

/// Collects `first` and whatever output is already queued behind it, until
/// the batch reaches `MAX_FRAME` (the output that crosses it is kept whole),
/// so a burst arrives in one frame. A control event is returned for the
/// caller to handle after the bytes, keeping their order.
fn batch_output(first: Bytes, rx: &mut broadcast::Receiver<Event>) -> (Bytes, Option<BatchEnd>) {
    let mut queued = Vec::new();
    let mut len = first.len();
    while len < MAX_FRAME {
        match rx.try_recv() {
            Ok(Event::Output(data)) => {
                len += data.len();
                queued.push(data);
            }
            Ok(Event::Bell) => return (join(first, queued), Some(BatchEnd::Bell)),
            Ok(Event::Exit) => return (join(first, queued), Some(BatchEnd::Exit)),
            Ok(Event::Restart) => return (join(first, queued), Some(BatchEnd::Restart)),
            Err(broadcast::error::TryRecvError::Empty) => break,
            Err(broadcast::error::TryRecvError::Closed) => {
                return (join(first, queued), Some(BatchEnd::Exit));
            }
            Err(broadcast::error::TryRecvError::Lagged(_)) => {
                return (join(first, queued), Some(BatchEnd::Lagged));
            }
        }
    }
    (join(first, queued), None)
}

/// One buffer for a batch. A lone chunk is sent as it came, without a copy.
fn join(first: Bytes, queued: Vec<Bytes>) -> Bytes {
    if queued.is_empty() {
        return first;
    }
    let mut batch = Vec::with_capacity(queued.iter().map(Bytes::len).sum::<usize>() + first.len());
    batch.extend_from_slice(&first);
    for data in queued {
        batch.extend_from_slice(&data);
    }
    batch.into()
}

/// What a text frame from the page asks for.
#[derive(Debug, PartialEq)]
enum Control {
    Resize {
        cols: u16,
        rows: u16,
    },
    /// Sent straight back: `{"ping": n}` gets `{"pong": n}`, so a page can
    /// tell a live socket from one a phone's sleep left for dead.
    Reply(String),
    Ignore,
}

fn control(text: &str) -> Control {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(text) else {
        return Control::Ignore;
    };
    if let (Some(cols), Some(rows)) = (v["cols"].as_u64(), v["rows"].as_u64()) {
        return Control::Resize {
            cols: cols as u16,
            rows: rows as u16,
        };
    }
    if !v["ping"].is_null() {
        return Control::Reply(serde_json::json!({ "pong": v["ping"] }).to_string());
    }
    Control::Ignore
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sessions::{Output, SCROLLBACK_BYTES};
    use axum::body::Bytes;
    use std::{
        collections::VecDeque,
        sync::{Arc, Mutex},
        time::{Duration, Instant},
    };

    // A scrollback that's full and wrapped around in its ring buffer, as a
    // busy shell's is.
    fn full() -> Output {
        let mut out = Output::new(VecDeque::new());
        for _ in 0..SCROLLBACK_BYTES / 4096 + 10 {
            out.append(Bytes::from(vec![b'x'; 4096]), false);
        }
        out
    }

    // Relative to a byte-by-byte walk over the same buffer, so the bound
    // holds on any machine. Only a debug build tells the two apart: release
    // optimises the walk into a copy too, so there it's not checked.
    #[test]
    fn a_replay_holds_the_output_lock_briefly() {
        if !cfg!(debug_assertions) {
            return;
        }
        let output = Mutex::new(full());
        // Best of a few, so a busy machine's one slow run doesn't count.
        let best = |f: &dyn Fn() -> usize| {
            (0..5)
                .map(|_| {
                    let t = Instant::now();
                    assert!(f() >= SCROLLBACK_BYTES);
                    t.elapsed()
                })
                .min()
                .unwrap()
        };
        let held = best(&|| output.lock().unwrap().replay(None).history.len());
        let walk = best(&|| {
            let out = output.lock().unwrap();
            out.scrollback.iter().copied().collect::<Vec<u8>>().len()
        });
        // The producer waits on this lock for every chunk it reads.
        assert!(held * 4 < walk, "held {held:?}, a byte walk {walk:?}");
    }

    #[test]
    fn a_replay_is_bounded_by_the_scrollback() {
        let mut out = full();
        out.append(Bytes::from_static(b"\x1b[?1049h"), false);
        for _ in 0..64 {
            out.append(Bytes::from(vec![b'y'; 8192]), false);
        }
        let replay = out.replay(None);
        assert!(
            replay.history.starts_with(b"\x1b[?1049h"),
            "trimmed modes first"
        );
        assert_eq!(
            replay.history.len(),
            SCROLLBACK_BYTES + b"\x1b[?1049h".len()
        );
        assert!(
            replay.history.ends_with(&[b'y'; 8192]),
            "the newest bytes last"
        );
    }

    // The seam between replay and live output: a client attaching while the
    // shell writes gets every chunk exactly once, either in its history or
    // on its receiver, in order.
    #[test]
    fn attaching_mid_stream_sees_every_chunk_once() {
        let output = Arc::new(Mutex::new(Output::new(VecDeque::new())));
        let producer = {
            let output = output.clone();
            std::thread::spawn(move || {
                // Fewer chunks than the channel holds, so no receiver lags.
                for i in 0..1000u32 {
                    let chunk = Bytes::from(format!("<{i}>"));
                    output.lock().unwrap().append(chunk, false);
                    std::thread::sleep(Duration::from_micros(50));
                }
            })
        };
        let mut attaches = Vec::new();
        while !producer.is_finished() {
            attaches.push(output.lock().unwrap().replay(None));
            std::thread::sleep(Duration::from_micros(200));
        }
        producer.join().unwrap();
        assert!(attaches.len() > 2, "attached while the shell wrote");
        for Replay {
            history, mut rx, ..
        } in attaches
        {
            let mut seen = history;
            while let Ok(Event::Output(data)) = rx.try_recv() {
                seen.extend_from_slice(&data);
            }
            let text = String::from_utf8(seen).unwrap();
            let ticks: Vec<u32> = text
                .split('<')
                .filter_map(|t| t.strip_suffix('>')?.parse().ok())
                .collect();
            assert_eq!(*ticks.last().unwrap(), 999, "live output up to the end");
            for w in ticks.windows(2) {
                assert_eq!(w[1], w[0] + 1, "no gap or repeat at {}", w[0]);
            }
        }
    }

    // A page that kept its screen asks for what came after the bytes it saw.
    #[test]
    fn a_resume_sends_only_the_bytes_missed() {
        let mut out = Output::new(VecDeque::from(b"old ".to_vec()));
        out.append(Bytes::from_static(b"seen "), false);
        let at = out.replay(None).at;
        out.append(Bytes::from_static(b"missed"), false);
        let epoch = out.epoch.clone();

        let resumed = out.replay(Some((&epoch, at)));
        assert!(resumed.resumed);
        assert_eq!(resumed.history, b"missed");
        assert_eq!(resumed.at, at + 6);

        let caught_up = out.replay(Some((&epoch, resumed.at)));
        assert!(caught_up.resumed);
        assert!(caught_up.history.is_empty());
    }

    // Anything it can't vouch for gets the whole scrollback again: another
    // shell's (or daemon's) count, bytes since trimmed off, or a count ahead.
    #[test]
    fn a_resume_it_cannot_honour_replays_everything() {
        let out = full();
        let epoch = out.epoch.clone();
        let whole = out.replay(None);
        assert!(!whole.resumed);
        for resume in [
            ("other", whole.at),
            (epoch.as_str(), 0),
            (epoch.as_str(), whole.at + 1),
        ] {
            let replay = out.replay(Some(resume));
            assert!(!replay.resumed, "{resume:?}");
            assert_eq!(replay.history.len(), whole.history.len(), "{resume:?}");
        }
        assert_ne!(
            Output::new(VecDeque::new()).epoch,
            epoch,
            "each shell counts afresh"
        );
    }

    #[test]
    fn a_resume_names_an_epoch_and_an_offset() {
        assert_eq!(resume_param("ab-1:42"), Some(("ab-1".into(), 42)));
        assert_eq!(resume_param("ab-1"), None);
        assert_eq!(resume_param("ab-1:x"), None);
    }

    fn output(rx: &mut broadcast::Receiver<Event>) -> Bytes {
        match rx.try_recv() {
            Ok(Event::Output(data)) => data,
            other => panic!("expected output, got {other:?}"),
        }
    }

    #[test]
    fn queued_output_is_coalesced_into_one_frame() {
        let (tx, mut rx) = broadcast::channel(16);
        for part in [&b"one"[..], b"two", b"three"] {
            tx.send(Event::Output(Bytes::copy_from_slice(part)))
                .unwrap();
        }
        let (batch, end) = batch_output(output(&mut rx), &mut rx);
        assert_eq!(&batch[..], b"onetwothree");
        assert_eq!(end, None);
    }

    #[test]
    fn a_lone_chunk_is_not_copied() {
        let (tx, mut rx) = broadcast::channel(16);
        let first = Bytes::from_static(b"solo");
        let ptr = first.as_ptr();
        tx.send(Event::Output(first.clone())).unwrap();
        let (batch, end) = batch_output(output(&mut rx), &mut rx);
        assert_eq!(batch.as_ptr(), ptr, "the common case reuses its buffer");
        assert_eq!(end, None);
    }

    #[test]
    fn a_control_event_ends_a_batch_in_order() {
        let (tx, mut rx) = broadcast::channel(16);
        tx.send(Event::Output(Bytes::from_static(b"before")))
            .unwrap();
        tx.send(Event::Bell).unwrap();
        tx.send(Event::Output(Bytes::from_static(b"after")))
            .unwrap();
        let (batch, end) = batch_output(output(&mut rx), &mut rx);
        assert_eq!(&batch[..], b"before");
        assert_eq!(end, Some(BatchEnd::Bell));
        assert_eq!(&output(&mut rx)[..], b"after", "the rest stays queued");
    }

    #[test]
    fn a_batch_stops_at_the_frame_cap() {
        let (tx, mut rx) = broadcast::channel(16);
        let chunk = Bytes::from(vec![b'x'; MAX_FRAME / 4]);
        for _ in 0..5 {
            tx.send(Event::Output(chunk.clone())).unwrap();
        }
        let (batch, end) = batch_output(output(&mut rx), &mut rx);
        assert_eq!(batch.len(), MAX_FRAME);
        assert_eq!(end, None);
        assert!(
            matches!(rx.try_recv(), Ok(Event::Output(_))),
            "output past the cap waits for the next frame"
        );
    }

    #[test]
    fn a_first_chunk_larger_than_the_cap_is_sent_whole() {
        let (tx, mut rx) = broadcast::channel(16);
        tx.send(Event::Output(Bytes::from(vec![b'x'; MAX_FRAME + 1])))
            .unwrap();
        tx.send(Event::Output(Bytes::from_static(b"next"))).unwrap();
        let (batch, end) = batch_output(output(&mut rx), &mut rx);
        assert_eq!(batch.len(), MAX_FRAME + 1);
        assert_eq!(end, None);
        assert_eq!(&output(&mut rx)[..], b"next");
    }

    #[test]
    fn a_closed_channel_ends_the_batch_as_an_exit() {
        let (tx, mut rx) = broadcast::channel(4);
        tx.send(Event::Output(Bytes::from_static(b"last"))).unwrap();
        drop(tx);
        let (batch, end) = batch_output(output(&mut rx), &mut rx);
        assert_eq!(&batch[..], b"last");
        assert_eq!(end, Some(BatchEnd::Exit));
    }

    #[test]
    fn a_text_frame_is_a_resize_a_ping_or_nothing() {
        assert_eq!(
            control(r#"{"cols":80,"rows":24}"#),
            Control::Resize { cols: 80, rows: 24 }
        );
        assert_eq!(
            control(r#"{"ping":7}"#),
            Control::Reply(r#"{"pong":7}"#.into())
        );
        assert_eq!(control("not json"), Control::Ignore);
        assert_eq!(control(r#"{"cols":80}"#), Control::Ignore);
    }
}
