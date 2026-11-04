#include "dscnn.h"
#include "dscnn_model_data.h"
#include <math.h>
#include <string.h>

static int8_t clamp8(int64_t value) {
    return (int8_t)(value < -128 ? -128 : value > 127 ? 127 : value);
}
static int64_t round_div(int64_t value,int64_t denominator) {
    return value < 0 ? -((-value+denominator/2)/denominator) : (value+denominator/2)/denominator;
}
/* Round nearest, ties away from zero, on the full product (no double rounding). */
static int64_t requant(int32_t acc,int32_t multiplier,int shift) {
    int64_t product=(int64_t)acc*multiplier;
    /* Magnitude shift preserves nearest/ties-away rounding without
       a runtime signed 64-bit division on Cortex-A9. Export uses 1..62. */
    uint64_t magnitude=product<0 ? (uint64_t)(-(product+1))+1 : (uint64_t)product;
    int64_t rounded=(int64_t)((magnitude+(UINT64_C(1)<<(shift-1)))>>shift);
    return product<0 ? -rounded : rounded;
}
static int8_t quantize(double value) {
    double scaled=value/DSCNN_INPUT_SCALE;
    double rounded=scaled < 0 ? -floor(-scaled+0.5) : floor(scaled+0.5);
    double q=rounded+DSCNN_INPUT_ZERO;
    if(q < -128) return -128;
    if(q > 127) return 127;
    return (int8_t)q;
}
int dscnn_quantize_ln(const float *features,int8_t *input) {
    int i;
    if(!features || !input) return -1;
    for(i=0;i<1960;i++) if(!isfinite(features[i])) return -2;
    for(i=0;i<1960;i++) input[i]=quantize(features[i]);
    return 0;
}
int dscnn_quantize_log2_q8_8(const int16_t *features,int8_t *input) {
    int i;
    if(!features || !input) return -1;
    /* PL power uses integer PCM; model features use PCM / 32767.0.
       Apply this offset exactly once, before input quantization. */
    for(i=0;i<1960;i++) input[i]=quantize((double)features[i]/256.0*0.69314718055994530942-20.794354380710768);
    return 0;
}

/* Four spatial positions share weight loads. No extra workspace or heap. */
static void pointwise(const DscnnLayer *l,const int8_t *in,int8_t *out) {
    int oc,p,ic,n=l->ih*l->iw;
    for(oc=0;oc<l->cout;oc++) {
        const int8_t *weights=l->weights+oc*l->cin;
        for(p=0;p<n;p+=4) {
            int count=n-p<4 ? n-p : 4;
            int32_t acc[4]={l->bias[oc],l->bias[oc],l->bias[oc],l->bias[oc]};
            for(ic=0;ic<l->cin;ic++) {
                const int8_t *v=in+ic*n+p;
                int weight=weights[ic],j;
                for(j=0;j<count;j++) acc[j]+=((int)v[j]-l->iz)*weight;
            }
            {
                int j;
                for(j=0;j<count;j++) {
                    int64_t q=requant(acc[j],l->multiplier[oc],l->shift[oc])+l->oz;
                    if(l->relu && q<l->oz) q=l->oz;
                    out[oc*n+p+j]=clamp8(q);
                }
            }
        }
    }
}

static void conv(const DscnnLayer *l,const int8_t *in,int8_t *out) {
    int oc,y,x,ic,ky,kx;
    int cpg=l->cin/l->groups,opg=l->cout/l->groups;
    if(l->k==1 && l->groups==1 && l->pad==0 && l->ih==l->oh && l->iw==l->ow) {
        pointwise(l,in,out);
        return;
    }
    for(oc=0;oc<l->cout;oc++) for(y=0;y<l->oh;y++) for(x=0;x<l->ow;x++) {
        int32_t acc=l->bias[oc];
        int base=(oc/opg)*cpg;
        for(ic=0;ic<cpg;ic++) for(ky=0;ky<l->k;ky++) for(kx=0;kx<l->k;kx++) {
            int iy=y+ky-l->pad,ix=x+kx-l->pad;
            if(iy>=0 && iy<l->ih && ix>=0 && ix<l->iw) {
                int value=(int)in[((base+ic)*l->ih+iy)*l->iw+ix]-l->iz;
                int weight=l->weights[((oc*cpg+ic)*l->k+ky)*l->k+kx];
                acc+=value*weight;
            }
            /* Out of bounds is real zero: quantized value iz, centered 0. */
        }
        int64_t q=requant(acc,l->multiplier[oc],l->shift[oc])+l->oz;
        if(l->relu && q<l->oz) q=l->oz;
        out[(oc*l->oh+y)*l->ow+x]=clamp8(q);
    }
}
static void pool(const DscnnLayer *l,const int8_t *in,int8_t *out) {
    int c,y,x,dy,dx;
    for(c=0;c<l->cout;c++) for(y=0;y<l->oh;y++) for(x=0;x<l->ow;x++) {
        int best=-128;
        for(dy=0;dy<2;dy++) for(dx=0;dx<2;dx++) {
            int value=in[(c*l->ih+y*2+dy)*l->iw+x*2+dx];
            if(value>best) best=value;
        }
        out[(c*l->oh+y)*l->ow+x]=(int8_t)best;
    }
}
static void gap(const DscnnLayer *l,const int8_t *in,int8_t *out) {
    int c,i,n=l->ih*l->iw;
    for(c=0;c<l->cin;c++) {
        int32_t total=0;
        for(i=0;i<n;i++) total+=(int)in[c*n+i]-l->iz;
        out[c]=clamp8(round_div(total,n)+l->oz);
    }
}
static void dense(const DscnnLayer *l,const int8_t *in,int8_t *out) {
    int oc,ic;
    for(oc=0;oc<l->cout;oc++) {
        int32_t acc=l->bias[oc];
        for(ic=0;ic<l->cin;ic++) acc+=((int)in[ic]-l->iz)*l->weights[oc*l->cin+ic];
        out[oc]=clamp8(requant(acc,l->multiplier[oc],l->shift[oc])+l->oz);
    }
}
int dscnn_infer(const int8_t *input,int8_t *output,DscnnWorkspace *w,DscnnTrace trace,void *context) {
    int i;
    const int8_t *src=input;
    int8_t *dst;
    if(!input || !output || !w) return -1;
    for(i=0;i<DSCNN_LAYER_COUNT;i++) {
        const DscnnLayer *l=&dscnn_layers[i];
        size_t count=(size_t)l->cout*l->oh*l->ow;
        if(count>DSCNN_MAX_ACTIVATION) return -2;
        dst=(i%2)==0 ? w->a : w->b;
        if(l->kind==0) conv(l,src,dst);
        else if(l->kind==1) pool(l,src,dst);
        else if(l->kind==2) gap(l,src,dst);
        else dense(l,src,dst);
        if(trace) trace(i,dst,count,context);
        src=dst;
    }
    memcpy(output,src,8);
    return 0;
}
DscnnResult dscnn_result(const int8_t *output) {
    int i,best=0;
    double sum=0;
    DscnnResult result;
    for(i=1;i<8;i++) if(output[i]>output[best]) best=i;
    for(i=0;i<8;i++) sum+=exp(((int)output[i]-(int)output[best])*DSCNN_OUTPUT_SCALE);
    result.class_id=(uint8_t)best;
    result.confidence_q8=(uint8_t)floor(255.0/sum+0.5);
    return result;
}
