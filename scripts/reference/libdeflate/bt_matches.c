/* Oracle for parts/lz77/bt_matchfinder.mbt. Build against the unmodified
 * https://github.com/ebiggers/libdeflate/releases/download/v1.24/libdeflate-1.24.tar.gz
 * after checking SOURCE.sha256; gen_vectors.mbtx does both, outside the repo.
 *
 * FNV-1a-64 over little-endian u32 words: absolute position, call kind
 * (0=get_matches, 1=skip_byte, 2=short tail), count, then length/offset pairs.
 * Modes: "all" queries every position; "level10" uses the long-match skip
 * heuristic in deflate_compress_near_optimal(). Both slide exactly as it does.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MATCHFINDER_WINDOW_ORDER 15
#include "lib/bt_matchfinder.h"

/* x86's inline initialization/rebase helpers may inspect runtime features.
 * Zero selects their baseline implementations; this changes no match lists. */
#if defined(ARCH_X86_32) || defined(ARCH_X86_64)
volatile u32 libdeflate_x86_cpu_features = 0;
void libdeflate_init_x86_cpu_features(void) {}
#endif

static uint64_t digest = UINT64_C(14695981039346656037);

static void word(uint32_t value)
{
    for (unsigned i = 0; i < 4; i++) {
        digest ^= (value >> (8 * i)) & 255;
        digest *= UINT64_C(1099511628211);
    }
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: bt_matches INPUT DEPTH NICE all|level10\n");
        return 2;
    }
    unsigned depth = (unsigned)strtoul(argv[2], NULL, 10);
    unsigned nice = (unsigned)strtoul(argv[3], NULL, 10);
    if (depth < 1 || nice < 5 || nice > 258 ||
        (strcmp(argv[4], "all") && strcmp(argv[4], "level10")))
        return 2;
    FILE *file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END)) return 2;
    long size = ftell(file);
    if (size < 0 || size > INT32_MAX || fseek(file, 0, SEEK_SET)) return 2;
    u8 *data = malloc(size ? (size_t)size : 1);
    if (!data || fread(data, 1, size, file) != (size_t)size) return 2;
    if (fclose(file)) return 2;
    struct bt_matchfinder *mf = aligned_alloc(32, sizeof(*mf));
    if (!mf) return 2;
    bt_matchfinder_init(mf);
    u32 hashes[2] = {0, 0};
    struct lz_match matches[258];
    size_t base = 0;
    unsigned skip = 0;
    for (size_t pos = 0; pos < (size_t)size; pos++) {
        if (pos - base == MATCHFINDER_WINDOW_SIZE) {
            bt_matchfinder_slide_window(mf);
            base = pos;
        }
        unsigned max_len = MIN(258, (size_t)size - pos);
        unsigned nice_len = MIN(nice, max_len);
        unsigned kind = skip ? 1 : 0;
        unsigned count = 0;
        if (max_len < BT_MATCHFINDER_REQUIRED_NBYTES) {
            kind = 2;
        } else if (skip) {
            bt_matchfinder_skip_byte(mf, data + base, pos - base,
                                    nice_len, depth, hashes);
        } else {
            count = bt_matchfinder_get_matches(mf, data + base, pos - base,
                                              max_len, nice_len, depth,
                                              hashes, matches) - matches;
        }
        word(pos);
        word(kind);
        word(count);
        for (unsigned i = 0; i < count; i++) {
            word(matches[i].length);
            word(matches[i].offset);
        }
        if (skip) {
            skip--;
        } else if (!strcmp(argv[4], "level10") && count &&
                   matches[count - 1].length >= nice_len) {
            skip = matches[count - 1].length - 1;
        }
    }
    printf("%" PRIu64 "\n", digest);
    free(mf);
    free(data);
    return 0;
}
