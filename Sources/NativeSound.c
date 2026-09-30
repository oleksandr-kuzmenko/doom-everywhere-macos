// Native macOS stereo sound effects. Engine/WAD access never occurs on the audio callback.
#include "NativeSound.h"
#include "i_sound.h"
#include "w_wad.h"
#include "z_zone.h"
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#define CHANNELS 16
#define FRAMES 512
#define RATE 44100
static pthread_mutex_t sound_lock = PTHREAD_MUTEX_INITIALIZER;
typedef struct Sample { int lump, rate; unsigned count; unsigned char *data; struct Sample *next; } Sample;
typedef struct { Sample *sample; double position; float left, right; } Channel;
static Sample *samples;
static Channel channels[CHANNELS];
static AudioQueueRef queue;
static atomic_int paused_audio, muted, ready, last_error;
static atomic_ullong sound_count, sample_count;
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;

static void render(void *context, AudioQueueRef output, AudioQueueBufferRef buffer) {
    (void)context;
    int16_t *pcm = buffer->mAudioData;
    memset(pcm, 0, FRAMES * 2 * sizeof(int16_t));
    if (!atomic_load(&paused_audio) && pthread_mutex_trylock(&sound_lock) == 0) {
        unsigned nonzero = 0;
        for (int frame=0; frame<FRAMES; ++frame) {
            float left=0, right=0;
            for(int c=0;c<CHANNELS;c++) {
                Channel *channel=&channels[c]; Sample *sample=channel->sample;
                if (!sample) continue;
                unsigned position=(unsigned)channel->position;
                if(position>=sample->count) { channel->sample=NULL; continue; }
                unsigned next=position+1<sample->count?position+1:position;
                float fraction=channel->position-position;
                float value=((sample->data[position]-128)*(1-fraction)+(sample->data[next]-128)*fraction)/128.0f;
                left+=value*channel->left; right+=value*channel->right;
                channel->position+=(double)sample->rate/RATE;
            }
            if(left!=0 || right!=0) nonzero++;
            if(atomic_load(&muted)) left=right=0;
            left*=0.35f; right*=0.35f;
            if(left>1)left=1; if(left< -1)left=-1; if(right>1)right=1; if(right< -1)right=-1;
            pcm[frame*2]=(int16_t)(left*32767); pcm[frame*2+1]=(int16_t)(right*32767);
        }
        atomic_fetch_add(&sample_count,nonzero);
        pthread_mutex_unlock(&sound_lock);
    }
    buffer->mAudioDataByteSize=FRAMES*2*sizeof(int16_t);
    AudioQueueEnqueueBuffer(output, buffer, 0, NULL);
}
static boolean initialize(boolean prefix) {
    (void)prefix;
    AudioStreamBasicDescription format={0};
    format.mSampleRate=RATE; format.mFormatID=kAudioFormatLinearPCM;
    format.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
    format.mBytesPerPacket=4; format.mFramesPerPacket=1; format.mBytesPerFrame=4;
    format.mChannelsPerFrame=2; format.mBitsPerChannel=16;
    OSStatus error=AudioQueueNewOutput(&format,render,NULL,NULL,NULL,0,&queue);
    if(!error) {
        for(int i=0;i<3 && !error;i++) {
            AudioQueueBufferRef buffer;
            error=AudioQueueAllocateBuffer(queue,FRAMES*4,&buffer);
            if(!error) render(NULL,queue,buffer);
        }
        if(!error) error=AudioQueueStart(queue,NULL);
    }
    atomic_store(&last_error,error);
    if(error) { if(queue)AudioQueueDispose(queue,true); queue=NULL; fprintf(stderr,"AudioQueue error: %d\n",(int)error); return false; }
    atomic_store(&ready,1); return true;
}
void DD_AudioShutdown(void) {
    atomic_store(&ready,0);
    if(queue) { AudioQueueDispose(queue,true); queue=NULL; }
    pthread_mutex_lock(&sound_lock);
    memset(channels,0,sizeof(channels));
    while(samples) { Sample *next=samples->next; free(samples->data); free(samples); samples=next; }
    pthread_mutex_unlock(&sound_lock);
}
static int lump_number(sfxinfo_t *sound) {
    char name[16]; snprintf(name,sizeof(name),"ds%s",sound->name); return W_GetNumForName(name);
}
static Sample *load_sample(int lump) {
    for(Sample *s=samples;s;s=s->next) if(s->lump==lump) return s;
    int size=W_LumpLength(lump); if(size<40)return NULL;
    const unsigned char *data=W_CacheLumpNum(lump,PU_STATIC);
    unsigned length=data[4]|data[5]<<8|data[6]<<16|(unsigned)data[7]<<24;
    int rate=data[2]|data[3]<<8;
    if(data[0]!=3 || data[1]!=0 || length<=32 || length>(unsigned)(size-8) || rate<1000 || rate>96000) {
        W_ReleaseLumpNum(lump); return NULL;
    }
    Sample *sample=calloc(1,sizeof(*sample));
    if(!sample) { W_ReleaseLumpNum(lump); return NULL; }
    sample->count=length-32; sample->data=malloc(sample->count);
    if(!sample->data) {free(sample);W_ReleaseLumpNum(lump);return NULL;}
    memcpy(sample->data,data+24,sample->count); W_ReleaseLumpNum(lump);
    sample->lump=lump; sample->rate=rate; sample->next=samples; samples=sample;
    return sample;
}
static void parameters(int channel,int volume,int separation) {
    if(channel<0 || channel>=CHANNELS)return;
    if(volume<0)volume=0; if(volume>127)volume=127;
    if(separation<0)separation=0; if(separation>254)separation=254;
    pthread_mutex_lock(&sound_lock);
    channels[channel].left=(volume/127.0f)*(254-separation)/254.0f;
    channels[channel].right=(volume/127.0f)*separation/254.0f;
    pthread_mutex_unlock(&sound_lock);
}
static int start(sfxinfo_t *sound,int channel,int volume,int separation) {
    if(channel<0 || channel>=CHANNELS || !atomic_load(&ready))return -1;
    // Only the engine thread loads samples; callback only reads immutable sample data.
    Sample *sample=load_sample(sound->lumpnum);
    if(!sample)return -1;
    parameters(channel,volume,separation);
    pthread_mutex_lock(&sound_lock);
    channels[channel].sample=sample; channels[channel].position=0;
    pthread_mutex_unlock(&sound_lock);
    atomic_fetch_add(&sound_count,1); return channel;
}
static void stop(int channel) {
    if(channel<0 || channel>=CHANNELS)return;
    pthread_mutex_lock(&sound_lock);channels[channel].sample=NULL;pthread_mutex_unlock(&sound_lock);
}
static boolean playing(int channel) {
    if(channel<0 || channel>=CHANNELS)return false;
    pthread_mutex_lock(&sound_lock);int value=channels[channel].sample!=NULL;pthread_mutex_unlock(&sound_lock);return value;
}
static void update(void) {}
static void cache(sfxinfo_t *s,int n) {(void)s;(void)n;}
static snddevice_t devices[]={SNDDEVICE_SB};
sound_module_t DG_sound_module={devices,1,initialize,DD_AudioShutdown,lump_number,update,parameters,start,stop,playing,cache};
// Music is explicitly disabled with -nomusic; a MUS/MIDI backend is a separate step.
music_module_t DG_music_module={0};
void DD_AudioPause(int value) {atomic_store(&paused_audio,!!value);}
void DD_AudioMute(int value) {atomic_store(&muted,!!value);}
int DD_AudioReady(void) {return atomic_load(&ready);}
int DD_AudioError(void) {return atomic_load(&last_error);}
uint64_t DD_AudioSounds(void) {return atomic_load(&sound_count);}
uint64_t DD_AudioSamples(void) {return atomic_load(&sample_count);}
