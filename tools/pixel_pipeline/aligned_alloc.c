#define _POSIX_C_SOURCE 200112L

#include "aligned_alloc.h"

#include <stdlib.h>

void *pp_aligned_alloc(size_t size)
{
    void *ptr = NULL;
    size_t bytes;

    if (size == 0) {
        size = 1;
    }
    if (size > (size_t)-1 - (PP_ALIGN_BYTES - 1u)) {
        return NULL;
    }
    bytes = (size + (PP_ALIGN_BYTES - 1u)) & ~(size_t)(PP_ALIGN_BYTES - 1u);
    if (posix_memalign(&ptr, PP_ALIGN_BYTES, bytes) != 0) {
        return NULL;
    }
    return ptr;
}

void pp_aligned_free(void *ptr)
{
    free(ptr);
}
