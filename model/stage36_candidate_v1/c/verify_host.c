/* Host-only verifier: inference itself uses no filesystem or heap. */
#include "dscnn.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static DscnnWorkspace workspace;
static int failures;
static const char *names[]={"conv0","block3_dw","block3_pw","pool3","block5_dw","block5_pw","block6_dw","block6_pw","pool6","block8_dw","block8_pw","global_average","head"};
static void check(int layer,const int8_t *data,size_t count,void *context) {
    char path[1024];
    size_t i,errors=0;
    FILE *f;
    snprintf(path,sizeof(path),"%s/%02d_%s.bin",(char *)context,layer,names[layer]);
    f=fopen(path,"rb");
    if(!f) { fprintf(stderr,"Cannot read %s\n",path); failures++; return; }
    for(i=0;i<count;i++) {
        int byte=fgetc(f);
        if(byte==EOF || (int8_t)(uint8_t)byte!=data[i]) errors++;
    }
    if(fgetc(f)!=EOF) errors++;
    fclose(f);
    printf("layer %d: %zu bytes, mismatches=%zu\n",layer,count,errors);
    if(errors) failures++;
}
int main(int argc,char **argv) {
    char path[1024];
    int8_t input[1960],output[8];
    FILE *f;
    DscnnResult result;
    if(argc!=2) return 2;
    snprintf(path,sizeof(path),"%s/input_int8.bin",argv[1]);
    f=fopen(path,"rb");
    if(!f) return 3;
    if(fread(input,1,1960,f)!=1960) return 4;
    fclose(f);
    if(dscnn_infer(input,output,&workspace,check,argv[1])) return 5;
    result=dscnn_result(output);
    printf("class_id=%u confidence_q8=%u scores:",result.class_id,result.confidence_q8);
    for(int i=0;i<8;i++) printf(" %d",output[i]);
    puts("");
    return failures ? 1 : 0;
}
