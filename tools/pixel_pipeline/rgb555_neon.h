#ifndef PP_RGB555_NEON_H
#define PP_RGB555_NEON_H

#include <stddef.h>
#include <stdint.h>

/* Real NEON converters are compiled only on AArch64 (NEON is mandatory there).
 * PP_FORCE_SCALAR keeps those functions in the binary for comparison but makes
 * the pipeline call the scalar path. */
#if (defined(__ARM_NEON) || defined(__ARM_NEON__)) && !defined(PP_FORCE_SCALAR)
#define PP_NEON_ENABLED 1
#else
#define PP_NEON_ENABLED 0
#endif

int pp_neon_enabled(void);

/* 1 when this binary contains the NEON implementations (even if the pipeline
 * was forced onto the scalar path). */
int pp_rgb555_neon_compiled(void);

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
/* Same contract as pp_rgb555_from_rgb8_n. Bit-identical to the scalar shift. */
void pp_rgb555_neon(const uint8_t *rgb, size_t count, uint16_t *dst);
#endif

#endif
