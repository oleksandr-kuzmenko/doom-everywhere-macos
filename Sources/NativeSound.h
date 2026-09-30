#ifndef DD_NATIVE_SOUND_H
#define DD_NATIVE_SOUND_H
#include <stdint.h>
void DD_AudioPause(int paused);
void DD_AudioMute(int muted);
int DD_AudioReady(void);
int DD_AudioError(void);
uint64_t DD_AudioSounds(void);
uint64_t DD_AudioSamples(void);
void DD_AudioShutdown(void);
#endif
