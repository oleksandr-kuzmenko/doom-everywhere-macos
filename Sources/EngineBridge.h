#ifndef DOCK_DOOM_ENGINE_BRIDGE_H
#define DOCK_DOOM_ENGINE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include "NativeSound.h"
#define DD_WIDTH 320
#define DD_HEIGHT 200
#define DD_FACE_SIZE 32
#define DD_FACE_BYTES (DD_FACE_SIZE * DD_FACE_SIZE * 4)
#define DD_FRAME_BYTES (DD_WIDTH * DD_HEIGHT * 4)
typedef struct {
    uint64_t frames, input_events;
    int running, finished, failed, paused, game_state, health, map, ammo, weapon, attacking;
    int32_t player_x, player_y;
} DDStats;
int DD_Start(const char *wad, const char *data_directory, int warp);
void DD_SetPaused(int paused);
void DD_Key(uint8_t key, int pressed);
void DD_ReleaseKeys(void);
int DD_CopyFrame(uint8_t *destination, size_t capacity, uint64_t *serial);
int DD_CopyFace(uint8_t *destination, size_t capacity);
DDStats DD_GetStats(void);
void DD_GetError(char *destination, size_t capacity);
void DD_Stop(void);
void DD_Join(void);
#endif
