/* Compile into Vitis Standalone together with dscnn.c; link libm (-lm).
   This function is the inference adapter, not a replacement for the state machine. */
#include "dscnn.h"
static DscnnWorkspace workspace;
static int8_t model_input[DSCNN_INPUT_COUNT];
static int8_t model_output[8];

int classify_pl_matrix(const int16_t signed_log2_q8_8[1960],DscnnResult *result) {
    int status;
    if(!result) return -1;
    /* Precondition: PL amplitude/power scaling and zero-energy floor were
       aligned with the model. This conversion does not perform AGC. */
    status=dscnn_quantize_log2_q8_8(signed_log2_q8_8,model_input);
    if(status) return status;
    status=dscnn_infer(model_input,model_output,&workspace,0,0);
    if(status) return status;
    *result=dscnn_result(model_output);
    /* Send result->class_id and result->confidence_q8 to existing Stage17 logic. */
    return 0;
}
