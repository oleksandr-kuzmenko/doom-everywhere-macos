// Platform adapter for doomgeneric. All engine access stays on one pthread.
#include "EngineBridge.h"
#include "doomgeneric.h"
#include "doomstat.h"
#include "d_items.h"
#include "i_system.h"
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static pthread_t worker;
static int started, worker_created, stop_requested, is_paused;
static double epoch, pause_start, paused_seconds;
static DDStats stats;
static char error_message[512];
static uint8_t rgba[DD_FRAME_BYTES], face_rgba[DD_FACE_BYTES];
static int face_available;
extern int DD_RenderStatusFace(uint8_t *destination);
static char *engine_argv[20];
static int engine_argc;
static struct { uint8_t key, pressed; } events[4096];
static unsigned head, tail;
static uint8_t desired[256], delivered[256];
static int resync;

static double monotonic(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void finished(void *unused) {
    (void)unused;
    DD_AudioShutdown();
    pthread_mutex_lock(&mutex);
    stats.running = 0; stats.finished = 1;
    pthread_cond_broadcast(&condition);
    pthread_mutex_unlock(&mutex);
}

// Upstream's generic I_Quit runs its exit handlers but returns to the engine.
// Only i_system.c is compiled with I_Quit renamed; finish this worker afterward.
void DD_OriginalQuit(void);
extern int show_endoom;
void I_Quit(void) {
    // The upstream ENDOOM callback calls exit(0); this host owns its lifecycle.
    show_endoom = 0;
    DD_OriginalQuit();
    pthread_exit(NULL);
}

// Route fatal engine errors to the shell instead of terminating the GUI process
// or displaying a system error window. i_system.c's original is renamed at build.
void I_Error(char *format, ...) {
    pthread_mutex_lock(&mutex);
    va_list arguments; va_start(arguments, format);
    vsnprintf(error_message, sizeof(error_message), format, arguments);
    va_end(arguments);
    stats.failed = 1;
    fprintf(stderr, "DOOM: %s\n", error_message);
    pthread_mutex_unlock(&mutex);
    pthread_exit(NULL);
}

static void gate(void) {
    pthread_mutex_lock(&mutex);
    while (is_paused && !stop_requested) pthread_cond_wait(&condition, &mutex);
    int stop = stop_requested;
    pthread_mutex_unlock(&mutex);
    if (stop) I_Quit();
}

static void *run_engine(void *unused) {
    (void)unused;
    pthread_cleanup_push(finished, NULL);
    doomgeneric_Create(engine_argc, engine_argv);
    for (;;) { gate(); doomgeneric_Tick(); }
    pthread_cleanup_pop(1);
    return NULL;
}

int DD_Start(const char *wad, const char *data_directory, int warp) {
    if (started) return 0; // Single engine instance per process.
    started = 1;
    // doomgeneric defaults config/save paths to cwd. The native shell supplies a
    // dedicated writable directory, never the signed app bundle or engine source.
    if (chdir(data_directory) != 0) {
        snprintf(error_message, sizeof(error_message), "Cannot access game data directory");
        stats.failed = stats.finished = 1; return 0;
    }
    const char *args[] = {"DOOM", "-iwad", wad, "-nomusic", "-nogui",
                          "-config", "default.cfg", "-extraconfig", "extra.cfg",
                          "-skill", "3", "-warp", "1"};
    engine_argc = warp ? 13 : 9;
    for (int i = 0; i < engine_argc; ++i) engine_argv[i] = strdup(args[i]);
    epoch = monotonic(); stats.running = 1;
    int result = pthread_create(&worker, NULL, run_engine, NULL);
    if (result) {
        snprintf(error_message, sizeof(error_message), "Cannot start engine thread: %d", result);
        stats.failed = stats.finished = 1; stats.running = 0; return 0;
    }
    worker_created = 1;
    return 1;
}

void DD_SetPaused(int value) {
    DD_AudioPause(value);
    pthread_mutex_lock(&mutex);
    value = !!value;
    if (value != is_paused) {
        if (value) pause_start = monotonic();
        else paused_seconds += monotonic() - pause_start;
        is_paused = value; stats.paused = value;
        pthread_cond_broadcast(&condition);
    }
    pthread_mutex_unlock(&mutex);
}

static void queue_key(uint8_t key, int pressed) {
    if (desired[key] == !!pressed) return;
    desired[key] = !!pressed;
    unsigned next = (head + 1) % 4096;
    if (next == tail) { tail = head; resync = 1; return; }
    events[head].key = key; events[head].pressed = !!pressed; head = next;
}
void DD_Key(uint8_t key, int pressed) {
    pthread_mutex_lock(&mutex); queue_key(key, pressed); pthread_mutex_unlock(&mutex);
}
void DD_ReleaseKeys(void) {
    pthread_mutex_lock(&mutex);
    for (int i = 0; i < 256; ++i) if (desired[i]) queue_key((uint8_t)i, 0);
    pthread_mutex_unlock(&mutex);
}
int DG_GetKey(int *pressed, unsigned char *key) {
    pthread_mutex_lock(&mutex);
    if (resync) {
        // Recover the actual desired state without leaving a key stuck on overflow.
        tail = head;
        for (int i = 0; i < 256; ++i) if (desired[i] != delivered[i]) {
            *key = i; *pressed = desired[i]; delivered[i] = desired[i];
            stats.input_events++; pthread_mutex_unlock(&mutex); return 1;
        }
        resync = 0;
    }
    if (head == tail) { pthread_mutex_unlock(&mutex); return 0; }
    *key = events[tail].key; *pressed = events[tail].pressed;
    delivered[*key] = *pressed; tail = (tail + 1) % 4096;
    stats.input_events++; pthread_mutex_unlock(&mutex); return 1;
}

void DG_Init(void) {}
void DG_SetWindowTitle(const char *title) { (void)title; }
void DG_DrawFrame(void) {
    // Read WAD patches on the engine thread, before locking (I_Error also locks).
    uint8_t face[DD_FACE_BYTES];
    int has_face = DD_RenderStatusFace(face);
    pthread_mutex_lock(&mutex);
    face_available = has_face;
    memcpy(face_rgba, face, sizeof(face));
    for (size_t i = 0; i < DD_WIDTH * DD_HEIGHT; ++i) {
        uint32_t pixel = DG_ScreenBuffer[i]; // upstream writes 0x00RRGGBB
        rgba[i*4] = pixel >> 16; rgba[i*4+1] = pixel >> 8;
        rgba[i*4+2] = pixel; rgba[i*4+3] = 255;
    }
    stats.frames++;
    stats.game_state = gamestate; stats.map = gamemap;
    stats.health = players[consoleplayer].health;
    stats.weapon = players[consoleplayer].readyweapon;
    int ammo_type = weaponinfo[stats.weapon].ammo;
    stats.ammo = ammo_type == am_noammo ? -1 : players[consoleplayer].ammo[ammo_type];
    stats.attacking = players[consoleplayer].attackdown;
    if (players[consoleplayer].mo) {
        stats.player_x = players[consoleplayer].mo->x;
        stats.player_y = players[consoleplayer].mo->y;
    }
    pthread_mutex_unlock(&mutex);
}
uint32_t DG_GetTicksMs(void) {
    gate();
    pthread_mutex_lock(&mutex);
    double elapsed = monotonic() - epoch - paused_seconds;
    pthread_mutex_unlock(&mutex);
    return (uint32_t)(elapsed * 1000) + 1;
}
void DG_SleepMs(uint32_t milliseconds) {
    gate();
    struct timespec duration = { milliseconds / 1000, (milliseconds % 1000) * 1000000L };
    nanosleep(&duration, NULL);
}
int DD_CopyFrame(uint8_t *destination, size_t capacity, uint64_t *serial) {
    if (capacity < DD_FRAME_BYTES) return 0;
    pthread_mutex_lock(&mutex);
    int changed = stats.frames && stats.frames != *serial;
    if (changed) { memcpy(destination, rgba, DD_FRAME_BYTES); *serial = stats.frames; }
    pthread_mutex_unlock(&mutex); return changed;
}
int DD_CopyFace(uint8_t *destination, size_t capacity) {
    if (capacity < DD_FACE_BYTES) return 0;
    pthread_mutex_lock(&mutex);
    int available = face_available;
    if (available) memcpy(destination, face_rgba, DD_FACE_BYTES);
    pthread_mutex_unlock(&mutex);
    return available;
}
DDStats DD_GetStats(void) {
    pthread_mutex_lock(&mutex); DDStats value = stats; pthread_mutex_unlock(&mutex); return value;
}
void DD_GetError(char *destination, size_t capacity) {
    pthread_mutex_lock(&mutex); snprintf(destination, capacity, "%s", error_message); pthread_mutex_unlock(&mutex);
}
void DD_Stop(void) {
    pthread_mutex_lock(&mutex); stop_requested = 1; pthread_cond_broadcast(&condition); pthread_mutex_unlock(&mutex);
}
void DD_Join(void) { if (worker_created && DD_GetStats().finished) { pthread_join(worker, NULL); worker_created = 0; } }
