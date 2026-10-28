#ifndef MSBC_WRAPPER_H
#define MSBC_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct msbc_ctx msbc_ctx;

msbc_ctx *msbc_new(void);
void msbc_free(msbc_ctx *ctx);

/* Decode one 60-byte mSBC frame (starting with 01 xx ad ...).
 * Returns samples per channel on success, -1 on error. */
int msbc_decode_frame(msbc_ctx *ctx, const uint8_t *frame60,
                      int16_t *pcm, int pcm_capacity);

#ifdef __cplusplus
}
#endif

#endif
