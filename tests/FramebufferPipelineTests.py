#!/usr/bin/env python3
"""Compile the production damage scan and send-lock guard on the host."""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "src/trollvncserver.mm").read_text()
hashing = source[source.index("#if defined(__aarch64__) || defined(__ARM_FEATURE_CRC32)\nNS_INLINE uint64_t crc32_update"):source.index("#pragma mark - Display Tiling\n")]
scan = source[source.index("NS_INLINE void resetCurrTileHashes"):source.index("NS_INLINE void markRectsModified")]
header = r"""
#include <stdint.h>
#include <stdio.h>
#include <cstring>
#include <cassert>
#include <cstddef>
#include <pthread.h>
#include <thread>
#include <future>
#define NS_INLINE static inline
static int gTileSize=32, gTilesX=2, gTilesY=2, gBytesPerPixel=4;
static int gWidth=64, gHeight=64;
static size_t gTileCount=4;
static uint64_t prev[4], curr[4];
static uint64_t *gPrevHash=prev, *gCurrHash=curr;
struct DirtyRect { int x,y,w,h; };
struct Client { pthread_mutex_t sendMutex = PTHREAD_MUTEX_INITIALIZER; int refs=0; };
struct Screen { Client *clients; size_t count; };
struct Iterator { Screen *screen; size_t index=0; Client* current=nullptr; };
using rfbClientIteratorPtr=Iterator*;
using rfbClientPtr=Client*;
using rfbScreenInfoPtr=Screen*;
static int iterators=0;
static void rfbIncrClientRef(Client* c) { ++c->refs; }
static void rfbDecrClientRef(Client* c) {
 assert(c->refs>0);
 if(--c->refs==0) {
  // A disconnected client may be destroyed as soon as its last reference is
  // released. Its send mutex must already have been unlocked at that point.
  assert(pthread_mutex_trylock(&c->sendMutex)==0);
  pthread_mutex_unlock(&c->sendMutex);
 }
}
static Iterator* rfbGetClientIterator(Screen* s) { ++iterators; return new Iterator{s}; }
static Client* rfbClientIteratorNext(Iterator* it) {
 if(it->current)rfbDecrClientRef(it->current);
 it->current=it->index < it->screen->count ? &it->screen->clients[it->index++] : nullptr;
 if(it->current)rfbIncrClientRef(it->current);
 return it->current;
}
static void rfbReleaseClientIterator(Iterator* it) {
 if(it->current)rfbDecrClientRef(it->current);
 --iterators; delete it;
}
#include "TryClientSendLocks.h"
#include "CaptureFrameState.h"
"""
main = r"""
int main() {
 CaptureFrameState capture;
 assert(capture.shouldCapture(0)); capture.didCapture(0);
 assert(!capture.shouldCapture(0));
 // Gate passes, capture consumes the change, then encoding starts before the
 // framebuffer handler: a busy-drop must request a retry of the static frame.
 assert(capture.shouldCapture(1)); capture.didCapture(1); capture.retry();
 assert(capture.shouldCapture(1)); capture.didCapture(1);
 assert(!capture.shouldCapture(1));
 capture.retry(); assert(capture.shouldCapture(1)); // static reconnect

 uint8_t buf[64*64*4]; for(size_t i=0;i<sizeof(buf);i++)buf[i]=(i*73+i/17)%256;
 DirtyRect rects[4]; int changed;
 hashTiledFromBuffer(buf,64,64,256); memcpy(prev,curr,sizeof(prev));
 hashTiledFromBuffer(buf,64,64,256);
 assert(buildDirtyRects(rects,4,&changed)==0 && changed==0);
 buf[0]^=1; hashTiledFromBuffer(buf,64,64,256);
 assert(buildDirtyRects(rects,4,&changed)==1 && changed==1);
 assert(rects[0].x==0 && rects[0].y==0 && rects[0].w==32 && rects[0].h==32);
 // A busy sender skips publication: retaining the baseline must preserve the
 // final changed screen on a retry even without a new animation frame.
 hashTiledFromBuffer(buf,64,64,256);
 assert(buildDirtyRects(rects,4,&changed)==1 && changed==1);
 memcpy(prev,curr,sizeof(prev)); hashTiledFromBuffer(buf,64,64,256);
 assert(buildDirtyRects(rects,4,&changed)==0 && changed==0);
 // Changes beyond a bounded rectangle list trigger the fullscreen fallback.
 buf[0]^=1; buf[(63*64+63)*4]^=1; hashTiledFromBuffer(buf,64,64,256);
 assert(buildDirtyRects(rects,1,&changed)==1);
 Client clients[65]; Screen screen{clients,2};
 rfbIncrClientRef(&clients[1]);
 std::promise<void> busy, release; auto released=release.get_future();
 std::thread sender([&]{pthread_mutex_lock(&clients[1].sendMutex);busy.set_value();released.wait();pthread_mutex_unlock(&clients[1].sendMutex);});
 busy.get_future().wait();
 { TryClientSendLocks locks(&screen); assert(!locks); }
 assert(iterators==0);
 assert(pthread_mutex_trylock(&clients[0].sendMutex)==0);pthread_mutex_unlock(&clients[0].sendMutex);
 release.set_value(); sender.join(); rfbDecrClientRef(&clients[1]);
 { TryClientSendLocks locks(&screen); assert(locks); assert(iterators==1); }
 assert(iterators==0);
 for(auto &client:clients) {assert(pthread_mutex_trylock(&client.sendMutex)==0);pthread_mutex_unlock(&client.sendMutex);}
 screen.count=65;
 { TryClientSendLocks locks(&screen);assert(!locks); }
 for(auto &client:clients) {assert(pthread_mutex_trylock(&client.sendMutex)==0);pthread_mutex_unlock(&client.sendMutex);pthread_mutex_destroy(&client.sendMutex);}
 assert(iterators==0);
 for(auto &client:clients)assert(client.refs==0);
 puts("PASS: unchanged/local damage, final-frame retry, rectangle overflow, busy sender and lock cleanup");
}
"""
with tempfile.TemporaryDirectory(prefix="trollvnc-frame-tests-") as temp:
    path = Path(temp) / "test.cpp"
    path.write_text(header + hashing + scan + main)
    command = ["clang++", "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread", "-I", str(ROOT / "src"), str(path), "-o", str(Path(temp) / "test")]
    if platform.machine() in ("arm64", "aarch64"):
        command.insert(1, "-march=armv8-a+crc")
    subprocess.run(command, check=True)
    subprocess.run([str(Path(temp) / "test")], check=True, timeout=10)
