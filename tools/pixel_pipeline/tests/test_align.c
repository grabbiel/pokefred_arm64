#include "aligned_alloc.h"
#include "test_common.h"

#include <stdint.h>
#include <string.h>

int main(void)
{
    void *a = pp_aligned_alloc(1);
    void *b = pp_aligned_alloc(1000);
    void *c = pp_aligned_alloc(128);
    unsigned char *bytes;

    REQUIRE(a != NULL);
    REQUIRE(b != NULL);
    REQUIRE(c != NULL);
    EXPECT(((uintptr_t)a % PP_ALIGN_BYTES) == 0);
    EXPECT(((uintptr_t)b % PP_ALIGN_BYTES) == 0);
    EXPECT(((uintptr_t)c % PP_ALIGN_BYTES) == 0);
    EXPECT(a != b && b != c);

    bytes = (unsigned char *)b;
    memset(bytes, 0xA5, 1000);
    EXPECT(bytes[0] == 0xA5 && bytes[999] == 0xA5);

    pp_aligned_free(a);
    pp_aligned_free(b);
    pp_aligned_free(c);
    pp_aligned_free(NULL);

    if (g_failures) {
        fprintf(stderr, "test_align: %d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_align: ok\n");
    return 0;
}
