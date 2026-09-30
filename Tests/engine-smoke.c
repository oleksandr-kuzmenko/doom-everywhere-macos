#include "EngineBridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
static DDStats wait_frames(unsigned long frames) {
    DDStats s = {0};
    for (int i=0;i<1000;i++) {
        s=DD_GetStats();
        if(s.frames>=frames || s.finished) break;
        usleep(10000);
    }
    if(s.failed) { char error[512]; DD_GetError(error,sizeof(error)); fprintf(stderr,"Engine error: %s\n",error); }
    return s;
}
int main(int argc,char **argv) {
    assert(argc==3 || argc==4);
    DD_AudioMute(1); // Verify synthesis without audible test noise.
    assert(DD_Start(argv[1],argv[2],1));
    if (argc==4 && strcmp(argv[3],"--expect-error")==0) {
        for(int i=0;i<500 && !DD_GetStats().finished;i++) usleep(10000);
        DDStats error=DD_GetStats(); assert(error.finished && error.failed);
        char message[512]; DD_GetError(message,sizeof(message)); assert(strlen(message)>0);
        DD_Join(); puts("PASS: missing WAD reports error without killing host process."); return 0;
    }
    DDStats before=wait_frames(55);
    assert(!before.failed && before.running && before.game_state==0 && before.health>0);
    static uint8_t face[DD_FACE_BYTES];
    assert(DD_CopyFace(face, sizeof(face)));
    int opaque = 0, transparent = 0;
    for (int i = 3; i < DD_FACE_BYTES; i += 4) {
        opaque += face[i] == 255; transparent += face[i] == 0;
    }
    assert(opaque > 100 && transparent > 0);
    assert(!DD_CopyFace(face, sizeof(face) - 1));
    // Enlarging the view hides the HUD; the independent face must remain available.
    for (int i = 0; i < 3; ++i) {
        DD_Key('=', 1); before = wait_frames(before.frames + 5);
        DD_Key('=', 0); before = wait_frames(before.frames + 5);
    }
    assert(DD_CopyFace(face, sizeof(face)));
    DD_Key(0xad,1); // Forward movement in E1M1.
    DDStats after=wait_frames(before.frames+25);
    DD_Key(0xad,0);
    assert(after.player_x!=before.player_x || after.player_y!=before.player_y);
    assert(after.input_events>0);
    DD_Key(0xa3,1); // Fire; prove ammo is actually consumed, not just input received.
    int ammo=after.ammo;
    DDStats firing=wait_frames(after.frames+40);
    DD_Key(0xa3,0);
    assert(firing.ammo<ammo && firing.weapon==after.weapon);
    assert(DD_AudioReady() && DD_AudioSounds()>0 && DD_AudioSamples()>0);
    DD_ReleaseKeys(); DD_SetPaused(1); usleep(100000);
    uint64_t count=DD_GetStats().frames; usleep(200000);
    assert(DD_GetStats().frames==count);
    static uint8_t pixels[DD_FRAME_BYTES]; uint64_t serial=0;
    assert(DD_CopyFrame(pixels,sizeof(pixels),&serial));
    int nonblack=0;
    for(int i=0;i<DD_FRAME_BYTES;i+=4) { assert(pixels[i+3]==255); nonblack+=pixels[i]||pixels[i+1]||pixels[i+2]; }
    assert(nonblack>1000);
    assert(!DD_CopyFrame(pixels,sizeof(pixels),&serial));
    DD_SetPaused(0); assert(wait_frames(count+5).frames>=count+5);
    DD_Stop();
    for(int i=0;i<300 && !DD_GetStats().finished;i++) usleep(10000);
    assert(DD_GetStats().finished && !DD_GetStats().failed);
    DD_Join();
    printf("PASS: E1M1 rendered; input moved player; fire consumed ammo; native audio produced samples; pause freezes frames; RGBA snapshot; transparent face without HUD; resume; clean stop.\n");
}
