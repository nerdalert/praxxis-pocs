# StreamBuffer Body Forwarding

## The Problem in One Sentence

Praxis reads the request body before choosing an upstream,
but the upstream must still receive the complete original
body — if it doesn't, inference backends get empty or
truncated prompts.

## Where This Happens in the MaaS Lifecycle

This is **step 7 in the BBR replacement flow** — the
moment between body inspection and upstream delivery:

```
Client → Gateway → Authorino → Praxis
                                  ↓
                          [1] request arrives
                          [2] model_to_header activates StreamBuffer
                          [3] body is read from downstream (client/gateway)
                          [4] JSON parsed, "model" extracted → header set
                          [5] filter returns Release
                          [6] router selects cluster by header
                          [7] ← THIS IS WHERE THE BUG WAS →
                              body must be sent to upstream
                          [8] upstream backend processes body
                          [9] response flows back to client
```

Step 7 is where Praxis hands the request to Pingora's
transport layer. Pingora connects to the upstream and
needs to send the body — but the body was already consumed
from the downstream connection during step 3. It has to
be *replayed* from a buffer.

## What "Replay" Means

Normal proxy flow: Pingora reads body chunks from
downstream and writes them to upstream simultaneously
(duplex mode). The body flows through.

StreamBuffer flow: Praxis reads the entire body from
downstream BEFORE connecting to upstream. The downstream
connection has no more body to read. Praxis stores the
body in a `VecDeque<Bytes>` called `pre_read_body`. When
Pingora later calls `request_body_filter()`, Praxis pops
chunks from this deque and hands them to Pingora as if
they just arrived — this is the "replay."

If replay fails, the upstream gets an empty body.

## What Was Broken (Two Issues)

### Issue 1: Praxis dropped post-Release chunks

In `stream_buffer.rs`, the pre-read loop only buffered
chunks while the filter hadn't returned `Release`:

```rust
// BROKEN: stops buffering after Release
if !released
    && let Some(ref b) = body
    && buffer.push(b.clone()).is_err()
```

If a multi-chunk body has chunks arriving after Release,
those chunks were consumed from downstream but never
stored. The replay deque was incomplete.

**Fix:** Remove the `!released` guard. Buffer all chunks.

```rust
// FIXED: always buffer
if let Some(ref b) = body {
    if buffer.push(b.clone()).is_err()
```

### Issue 2: Pingora never called the replay callback

After Praxis pre-reads the body, downstream is "done."
Pingora's transport layer decides whether to do an initial
body send to upstream based on:

```rust
// Pingora's gate for initial body send
if buffer.is_some() || session.is_body_empty() {
    send_body_to_pipe(...)  // calls request_body_filter
}
```

When StreamBuffer pre-read consumed the body:
- `buffer` (retry buffer) is `None` — Praxis doesn't use retries
- `is_body_empty()` is `false` — the request had a body

So Pingora skips the initial send. It enters the duplex
loop, where `read_body_or_idle(done=true)` calls `idle()`
— which waits for the TCP connection to close. The upstream
never gets the body. Nobody moves. The request hangs until
the client times out.

```
Pingora:  "downstream is done, I'll idle and wait for close"
Upstream: "I'm waiting for the request body..."
Client:   "I'm waiting for a response..."
→ deadlock until client timeout
```

**Fix (in Pingora):** Also trigger the initial send when
downstream is already done:

```rust
// FIXED: also send when downstream already consumed
if buffer.is_some() || session.is_body_empty() || downstream_state.is_done() {
    send_body_to_pipe(...)
}
```

This ensures `request_body_filter()` is called, which
pops the replay deque and sends the body upstream.

## End-to-End Flow After Both Fixes

1. **Client sends request.** POST with JSON body
   containing `{"model":"qwen","messages":[...]}`.
   Arrives at Praxis listener via gateway.

2. **Praxis enters StreamBuffer pre-read.** The
   `model_to_header` filter declared `StreamBuffer`
   body mode, so `pre_read_body()` starts reading
   the body from the downstream connection.

3. **Chunk 1 arrives from downstream.** Praxis reads
   it and pushes it into the buffer. The filter
   pipeline runs on this chunk — `model_to_header`
   parses the JSON, extracts `"model": "qwen"`, and
   promotes it to header `X-AI-Model: qwen`. The
   filter returns `Release`.

4. **Chunk 2 arrives (or end-of-stream on same read).**
   Praxis reads it and pushes it into the buffer.
   **FIX 1:** previously, post-Release chunks were
   skipped. Now all chunks are buffered regardless.

5. **End-of-stream reached.** The downstream body is
   fully consumed. Praxis freezes the buffer into a
   `Bytes` blob and stores it in `ctx.pre_read_body`
   (a `VecDeque`).

6. **Router and load balancer run.** The router
   matches on the promoted `X-AI-Model` header and
   selects a cluster. The load balancer picks an
   endpoint from that cluster.

7. **Handoff to Pingora transport.** Praxis returns
   control to Pingora with a selected upstream peer.
   Pingora connects to the upstream backend.

8. **Pingora checks whether to do initial body send.**
   Downstream is already done (body fully consumed in
   step 2-5). **FIX 2:** Pingora now recognizes
   `downstream_done == true` as a reason to enter the
   initial send path. Previously it skipped this and
   entered an idle deadlock.

9. **Pingora calls `request_body_filter()`.** This is
   Praxis's replay callback. Praxis pops the stored
   body from `ctx.pre_read_body` and returns it to
   Pingora as if it just arrived from downstream.

10. **Pingora sends body to upstream.** The complete
    original body is written to the upstream connection.
    The upstream backend receives the full JSON payload.

11. **Upstream processes and responds.** The response
    flows back through Pingora → Praxis → gateway →
    client.

## Why Both Fixes Are Required

| Fix | Without it |
|-----|-----------|
| Praxis buffer fix only | All chunks stored, but `request_body_filter` is never called — deadlock |
| Pingora initial-send fix only | Callback fires, but replay deque may be incomplete for multi-chunk bodies |
| Both | Complete body stored AND replayed to upstream |

## Where the Fixes Live

| Fix | Repo | Branch | File |
|-----|------|--------|------|
| Buffer all chunks | `nerdalert/praxis` | `feat/dns-and-request-headers` | `protocol/src/http/pingora/handler/request_filter/stream_buffer.rs` |
| Initial send when done | `nerdalert/pingora` | `feat/streambuffer-initial-send` | `pingora-proxy/src/proxy_h1.rs`, `proxy_h2.rs`, `proxy_custom.rs`, `proxy_common.rs` |

Praxis's `Cargo.toml` points to the `nerdalert/pingora`
fork so both fixes ship in the same image.
