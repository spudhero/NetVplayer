/* Offline HRTF and synthetic pose tests; no device or motion permission.
 * SPDX-License-Identifier: LGPL-2.1-or-later */
#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "atmos_binaural.h"

static float *render(int channel, float yaw, float pitch, float roll, bool reset)
{
    void *h = nv_binaural_create(48000,false); assert(h);
    assert(nv_binaural_set_test_orientation(h,yaw,pitch,roll));
    float samples[24][160]={0}, l[160], r[160], *planes[24];
    for (int c=0;c<24;c++) planes[c]=samples[c];
    float *out=calloc(8000,sizeof(float)); assert(out);
    for (int b=0;b<100;b++) {
        for (int f=0;f<40;f++) samples[channel][f]=b<50 ? .1f*sinf((b*40+f)*.13f) : 0;
        assert(nv_binaural_render(h,planes,40,l,r));
        for (int f=0;f<40;f++) { out[(b*40+f)*2]=l[f]; out[(b*40+f)*2+1]=r[f]; }
    }
    struct nv_binaural_status s;
    nv_binaural_get_status(h,&s);
    assert(s.frames==4000 && !s.tracking_active && s.poses==0 && !s.tracking_requested);
    if (reset) {
        nv_binaural_reset(h); memset(samples,0,sizeof(samples));
        for (int b=0;b<10;b++) {
            assert(nv_binaural_render(h,planes,40,l,r));
            for (int f=0;f<40;f++) assert(fabsf(l[f])+fabsf(r[f])<1e-7);
        }
    }
    nv_binaural_destroy(h);
    return out;
}

int main(void)
{
    @autoreleasepool {
        double energy[12][2]={0};
        for (int c=0;c<12;c++) {
            float *p=render(c,0,0,0,true);
            for (int f=0;f<4000;f++) for (int ear=0;ear<2;ear++) {
                assert(isfinite(p[f*2+ear])); energy[c][ear]+=p[f*2+ear]*p[f*2+ear];
            }
            assert(energy[c][0]+energy[c][1]>1e-6); free(p);
        }
        assert(energy[0][0]>energy[0][1] && energy[1][1]>energy[1][0]);
        assert(energy[8][0]>energy[8][1] && energy[9][1]>energy[9][0]);
        float *front=render(2,0,0,0,false), *turned=render(2,90,0,0,false);
        float *locked=render(14,90,0,0,false);
        double change=0, lock_error=0;
        for (int i=0;i<8000;i++) { change+=fabs(front[i]-turned[i]); lock_error+=fabs(front[i]-locked[i]); }
        assert(change>1 && lock_error<.01);
        free(turned); free(locked);
        // All three rotations influence world sources; a head-locked source
        // stays relative to the listener through combined rotations as well.
        locked=render(14,30,20,15,false);
        lock_error=0; for(int i=0;i<8000;i++) lock_error+=fabs(front[i]-locked[i]);
        assert(lock_error<.05);
        free(front); free(locked);
        puts("PASS: 12 virtual speakers, 40-frame consumption, finite stereo output, reset clears tails, synthetic rotation, head-lock, no sensor claims");
    }
}
