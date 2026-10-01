# ZXTouch protocol core

This directory contains TrollVNC's independently implemented ZXTouch TCP
protocol core, under GPL-2.0-only. It is compiled from source into the server;
no prebuilt binary is required.

Wire compatibility was checked against `gitssie/zxtouchrootless`, particularly
its Python client and task constants. No upstream implementation is copied:
the upstream repository carries GPLv3, while TrollVNC carries GPLv2-only.

Commands are a two-digit task ID followed immediately by the payload and CRLF.
Payload fields use `;;`. Touch (10) has no response. Other commands respond
with `0[;;fields]\r\n` or `-1;;message\r\n`. Screenshot (30) responds with
`0;;image/jpeg;;length\r\n` followed by exactly `length` binary bytes.
Recording and phone-side script playback are intentionally excluded.
