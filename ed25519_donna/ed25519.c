#include <stddef.h>
#include <stdint.h>

typedef struct ed25519_hash_context {
    uint8_t s[200];
    size_t offset;
    size_t rate;
} ed25519_hash_context;

void ed25519_hash(uint8_t *hash, const uint8_t *in, size_t inlen);
void ed25519_hash_init(ed25519_hash_context *ctx);
void ed25519_hash_update(ed25519_hash_context *ctx, const uint8_t *in, size_t inlen);
void ed25519_hash_final(ed25519_hash_context *ctx, uint8_t *hash);
void ed25519_hash(uint8_t *hash, const uint8_t *in, size_t inlen);

#include "lib/ed25519.c"