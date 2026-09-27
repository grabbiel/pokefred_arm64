/* Vendored decoder implementation. Compiled with warnings off (third-party).
 * STB_IMAGE_STATIC keeps stbi_* inside this translation unit so
 * libpixel_pipeline does not export them. */
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_LINEAR
#define STBI_NO_HDR
/* Keep PNG decode identical on x86_64 and AArch64. Our NEON code is separate. */
#define STBI_NO_SIMD
#include "stb_image.h"
#include "png_stb.h"

unsigned char *pp_png_stbi_load_from_memory(const unsigned char *buffer, int len, int *x, int *y,
                                            int *channels_in_file, int desired_channels)
{
    return stbi_load_from_memory(buffer, len, x, y, channels_in_file, desired_channels);
}

void pp_png_stbi_image_free(void *retval_from_load)
{
    stbi_image_free(retval_from_load);
}

const char *pp_png_stbi_failure_reason(void)
{
    return stbi_failure_reason();
}
