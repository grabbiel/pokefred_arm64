#ifndef PP_PNG_STB_H
#define PP_PNG_STB_H

/* Private. stb_image is compiled static in third_party/stb_image_impl.c. */

unsigned char *pp_png_stbi_load_from_memory(const unsigned char *buffer, int len, int *x, int *y,
                                            int *channels_in_file, int desired_channels);
void pp_png_stbi_image_free(void *retval_from_load);
const char *pp_png_stbi_failure_reason(void);

#endif
