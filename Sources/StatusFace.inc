// Included only by the generated st_stuff.c copy to access its private face state.
// Decode the current WAD sprite independently of HUD visibility, menus and wipes.
#include "EngineBridge.h"
#include "i_swap.h"
#include <string.h>

int DD_RenderStatusFace(uint8_t *destination) {
    memset(destination, 0, DD_FACE_BYTES);
    if (gamestate != GS_LEVEL || !faces[st_faceindex]) return 0;
    patch_t *patch = faces[st_faceindex];
    const byte *palette = W_CacheLumpName("PLAYPAL", PU_CACHE);
    int width = SHORT(patch->width), height = SHORT(patch->height);
    if (width <= 0 || width > DD_FACE_SIZE || height <= 0 || height > DD_FACE_SIZE) return 0;
    int left = (DD_FACE_SIZE - width) / 2, top = (DD_FACE_SIZE - height) / 2;
    for (int x = 0; x < width; ++x) {
        const byte *column = (const byte *)patch + LONG(patch->columnofs[x]);
        while (column[0] != 255) {
            int start = column[0], length = column[1];
            for (int i = 0; i < length && start + i < height; ++i) {
                int pixel = ((top + start + i) * DD_FACE_SIZE + left + x) * 4;
                int color = column[3 + i] * 3;
                memcpy(destination + pixel, palette + color, 3);
                destination[pixel + 3] = 255;
            }
            column += length + 4;
        }
    }
    return 1;
}
