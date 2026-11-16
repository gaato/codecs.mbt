/* Raw-DEFLATE oracle, linked with the pinned, streaming-limit-patched 1.24
 * sources by gen_vectors.mbtx. The output file is hashed by the generator. */
#include <stdio.h>
#include <stdlib.h>
#include "libdeflate.h"

int main(int argc, char **argv)
{
    if (argc != 4) return 2;
    int level = atoi(argv[2]);
    if (level < 0 || level > 12) return 2;
    FILE *in = fopen(argv[1], "rb");
    if (!in || fseek(in, 0, SEEK_END)) return 2;
    long size = ftell(in);
    if (size < 0 || fseek(in, 0, SEEK_SET)) return 2;
    unsigned char *data = malloc(size ? (size_t)size : 1);
    if (!data || fread(data, 1, size, in) != (size_t)size || fclose(in)) return 2;
    struct libdeflate_compressor *c = libdeflate_alloc_compressor(level);
    if (!c) return 2;
    size_t capacity = libdeflate_deflate_compress_bound(c, size);
    unsigned char *output = malloc(capacity);
    if (!output) return 2;
    size_t length = libdeflate_deflate_compress(c, data, size, output, capacity);
    FILE *out = fopen(argv[3], "wb");
    if (!length || !out || fwrite(output, 1, length, out) != length || fclose(out)) return 2;
    libdeflate_free_compressor(c);
    free(output);
    free(data);
    return 0;
}
