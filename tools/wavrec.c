/* Preloaded into Mesen's test runner (MESEN_PRELOAD, see ~/.local/bin/mesen2) so that a Lua
   script can start and stop the core's sound recorder, which the Lua API does not reach and
   whose Lua cannot load a library.  The script creates $MESEN_WAV.start (or .stop) and
   waits for the file to go away; the thread here calls the core's WaveRecord / WaveStop in
   between, so the recording begins and ends at a frame the script knows.
   $MESEN_CORE is the path of the loaded MesenCore.so (~/.config/Mesen2/MesenCore.so).
   Built by tools/video.py:  gcc -shared -fPIC -O1 -o build/wavrec.so tools/wavrec.c -ldl -lpthread */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static char wav[1024], f_start[1040], f_stop[1040], core[1024];
static void *sym(const char *name) {
  void *h = dlopen(core, RTLD_NOLOAD | RTLD_LAZY);     /* NULL in any process without the core */
  return h ? dlsym(h, name) : NULL;
}
static void *run(void *arg) {
  (void)arg;
  for (;;) {
    if (access(f_start, F_OK) == 0) {
      void (*f)(char *) = (void (*)(char *))sym("WaveRecord");
      if (f) { f(wav); unlink(f_start); }
    }
    if (access(f_stop, F_OK) == 0) {
      void (*f)(void) = (void (*)(void))sym("WaveStop");
      if (f) { f(); unlink(f_stop); }
    }
    usleep(500);
  }
  return NULL;
}
__attribute__((constructor)) static void init(void) {
  const char *p = getenv("MESEN_WAV"), *c = getenv("MESEN_CORE");
  pthread_t t;
  if (!p || !c) return;
  snprintf(wav, sizeof wav, "%s", p);
  snprintf(f_start, sizeof f_start, "%s.start", p);
  snprintf(f_stop, sizeof f_stop, "%s.stop", p);
  snprintf(core, sizeof core, "%s", c);
  pthread_create(&t, NULL, run, NULL);
}
