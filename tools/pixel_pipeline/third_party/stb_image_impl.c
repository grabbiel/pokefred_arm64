/* Vendored decoder implementation. Compiled with warnings off (third-party). */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_LINEAR
#define STBI_NO_HDR
/* Keep PNG decode identical on x86_64 and AArch64. Our NEON code is separate. */
#define STBI_NO_SIMD
#include "stb_image.h"
