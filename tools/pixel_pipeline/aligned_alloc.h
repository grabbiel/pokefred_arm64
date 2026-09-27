#ifndef PP_ALIGNED_ALLOC_H
#define PP_ALIGNED_ALLOC_H

#include <stddef.h>

/* Apple Silicon cache-line size. Every pipeline buffer uses this, including
 * on x86_64, so tests assert the same contract everywhere. */
#define PP_ALIGN_BYTES 128u

void *pp_aligned_alloc(size_t size);
void pp_aligned_free(void *ptr);

#endif
