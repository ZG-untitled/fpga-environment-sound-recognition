#ifndef DSCNN_H
#define DSCNN_H
#include <stdint.h>
#include <stddef.h>
#define DSCNN_INPUT_COUNT 1960
#define DSCNN_MAX_ACTIVATION 109760
typedef struct {
    int kind,cin,ih,iw,cout,oh,ow,k,pad,groups,iz,oz,relu;
    const int8_t *weights;
    const int32_t *bias,*multiplier,*shift;
} DscnnLayer;
/* Allocate statically or in DDR; do not put this on the small BSP stack. */
typedef struct { int8_t a[DSCNN_MAX_ACTIVATION],b[DSCNN_MAX_ACTIVATION]; } DscnnWorkspace;
/* Callback data is valid only during the callback. layer counts from zero. */
typedef void (*DscnnTrace)(int layer,const int8_t *data,size_t count,void *context);
typedef struct { uint8_t class_id,confidence_q8; } DscnnResult;
int dscnn_quantize_ln(const float ln_features[1960],int8_t input[1960]);
/* Signed Log2 Q8.8. log2(0) cannot be reconstructed from numeric zero.
   Correct PL zero/floor handling upstream; zero may also mean log2(1). */
int dscnn_quantize_log2_q8_8(const int16_t log2_features[1960],int8_t input[1960]);
int dscnn_infer(const int8_t input[1960],int8_t output[8],DscnnWorkspace *workspace,
                DscnnTrace trace,void *context);
DscnnResult dscnn_result(const int8_t output[8]);
#endif
