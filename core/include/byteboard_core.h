// C interface to byteboard-core. See core/src/ffi.rs for the contract of each call.
#ifndef BYTEBOARD_CORE_H
#define BYTEBOARD_CORE_H

#include <stddef.h>
#include <stdint.h>

typedef struct BBEngine BBEngine;

BBEngine *bb_engine_new(void);
void bb_engine_free(BBEngine *engine);

/// 0 on success; negative on error.
int32_t bb_engine_add_dict(BBEngine *engine, const uint8_t *path, size_t len);
/// Letter rows separated by '|', top row first.
int32_t bb_engine_set_layout(BBEngine *engine, const uint8_t *rows, size_t len);
uint32_t bb_engine_dict_count(const BBEngine *engine);

/// Writes "kind\tword\n" lines (kind: c completion, x correction, n next word).
/// Returns bytes written, or -(bytes needed) when cap is too small.
intptr_t bb_engine_suggest(const BBEngine *engine, const uint8_t *before, size_t len,
                           uint32_t max, uint8_t *out, size_t cap);

#endif
