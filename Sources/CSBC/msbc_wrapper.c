#include "msbc_wrapper.h"
#include "sbc.h"

#include <stdlib.h>

struct msbc_ctx {
    sbc_t sbc;
};

msbc_ctx *msbc_new(void) {
    msbc_ctx *ctx = (msbc_ctx *)calloc(1, sizeof(*ctx));
    if (ctx) {
        sbc_reset(&ctx->sbc);
    }
    return ctx;
}

void msbc_free(msbc_ctx *ctx) {
    free(ctx);
}

int msbc_decode_frame(msbc_ctx *ctx, const uint8_t *frame60,
                      int16_t *pcm, int pcm_capacity) {
    if (!ctx || !frame60 || !pcm) {
        return -1;
    }

    /* The mSBC SBC frame starts at the 0xAD sync word, two bytes into the
     * 60-byte HFP frame: 01 xx | AD ... */
    const uint8_t *frame = frame60 + 2;
    struct sbc_frame desc;
    if (sbc_probe(frame, &desc) < 0) {
        return -1;
    }

    int channels = 1 + (desc.mode != SBC_MODE_MONO);
    int samples = desc.nblocks * desc.nsubbands;
    if (samples * channels > pcm_capacity) {
        return -1;
    }

    if (sbc_decode(&ctx->sbc, frame, SBC_MSBC_SIZE, &desc,
                   pcm, channels, pcm + 1, 2) < 0) {
        return -1;
    }
    return samples;
}
