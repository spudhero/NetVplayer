/* Digital routing/timing tests; no audio hardware. SPDX-License-Identifier: LGPL-2.1-or-later */
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "atmos_render.h"

static float audio[16][160], output[24][160];
static const float *channels[16];
static float *planes[24];
static uint8_t speakers[16];
static struct nv_atmos_renderer renderer;
static void near(float a, float b) { assert(fabsf(a-b) < 1e-5f); }
static void silence_except(unsigned frames, int a, int b)
{
    for (int c = 0; c < 24; c++) if (c != a && c != b)
        for (unsigned f = 0; f < frames; f++) near(output[c][f], 0);
}

int main(void)
{
    for (int i = 0; i < 16; i++) { channels[i] = audio[i]; for (int f = 0; f < 160; f++) audio[i][f] = 1; }
    for (int c = 0; c < 24; c++) planes[c] = output[c];
    uint8_t bed[] = {0,1,2,3,14,15,4,5,6,7,10,11};
    TrueHDAtmosBlock b = {.sample_rate=48000, .frame_count=16, .channel_count=1,
        .presentation=3, .layout_serial=1, .channels=channels, .speakers=speakers};
    // All twelve labels route individually, including four distinct heights.
    for (int i = 0; i < 12; i++) {
        speakers[0] = bed[i]; nv_atmos_reset(&renderer);
        assert(nv_atmos_render(&renderer,&b,planes) == 0);
        for (int f = 0; f < 16; f++) near(output[i][f],1);
        silence_except(16,i,-1);
    }
    speakers[0] = TRUEHD_ATMOS_SPEAKER_TSL; nv_atmos_reset(&renderer);
    assert(nv_atmos_render(&renderer,&b,planes) == 0);
    near(output[8][0],sqrtf(.5)); near(output[10][0],sqrtf(.5)); silence_except(16,8,10);
    speakers[0] = TRUEHD_ATMOS_SPEAKER_OBJECT; nv_atmos_reset(&renderer);
    assert(nv_atmos_render(&renderer,&b,planes) == 0); silence_except(16,-1,-1);
    TrueHDAtmosElement e = {.kind=TRUEHD_ATMOS_ELEMENT_OBJECT, .speaker=TRUEHD_ATMOS_SPEAKER_OBJECT,
        .flags=TRUEHD_ATMOS_ELEMENT_ACTIVE|TRUEHD_ATMOS_ELEMENT_CHANGED|TRUEHD_ATMOS_ELEMENT_ELEVATION,
        .gain=1, .position={.25,.25,1}};
    TrueHDAtmosMetadataUpdate u = {.frame_offset=3,.ramp_frames=999,.elements=&e};
    TrueHDAtmosMetadata m = {.element_count=1,.dynamic_count=1,.update_count=1,.updates=&u,.elements=&e};
    b.metadata=&m;
    assert(nv_atmos_render(&renderer,&b,planes) == 0);
    for (int f = 0; f < 16; f++) near(output[8][f],f<3?0:1); silence_except(16,8,-1);
    // An interrupted movement starts from the current gain, and unchanged
    // restatements never restart an unfinished ramp.
    b.frame_count=2; u.frame_offset=0; u.ramp_frames=4; e.position[0]=.75;
    assert(nv_atmos_render(&renderer,&b,planes)==0);
    near(output[8][0],.75); near(output[9][0],.25); near(output[8][1],.5);
    e.flags &= ~TRUEHD_ATMOS_ELEMENT_CHANGED;
    assert(nv_atmos_render(&renderer,&b,planes)==0);
    near(output[8][0],.25); near(output[9][0],.75); near(output[8][1],0); near(output[9][1],1);
    e.flags |= TRUEHD_ATMOS_ELEMENT_CHANGED; e.position[0]=.25;
    assert(nv_atmos_render(&renderer,&b,planes)==0); near(output[8][1],.5);
    e.position[0]=.75;
    assert(nv_atmos_render(&renderer,&b,planes)==0); near(output[8][0],.375); near(output[9][0],.625);
    // Discontinuity discards ramps, and does not fabricate an object position.
    b.flags=TRUEHD_ATMOS_BLOCK_DISCONTINUITY; b.metadata=NULL;
    assert(nv_atmos_render(&renderer,&b,planes)==0); silence_except(2,-1,-1);
    b.flags=0; b.metadata=&m; u.ramp_frames=0;
    e.flags |= TRUEHD_ATMOS_ELEMENT_HEAD_TRACK_DISABLE;
    assert(nv_atmos_render(&renderer,&b,planes)==0); near(output[21][0],1); silence_except(2,21,-1);
    e.flags &= ~TRUEHD_ATMOS_ELEMENT_ACTIVE;
    assert(nv_atmos_render(&renderer,&b,planes)==0); silence_except(2,-1,-1);
    // Unsupported ISF uses only the sample-aligned complete channel mix.
    m.isf_count=1; b.bed_channel_count=1; b.bed_speakers=bed; b.bed_channels=channels;
    assert(nv_atmos_render(&renderer,&b,planes)==1); near(output[0][0],1); silence_except(2,0,-1);
    b.bed_channel_count=0; assert(nv_atmos_render(&renderer,&b,planes)==-1);
    // Spatial power is bounded and objects never send bass to LFE.
    for (int zone=0; zone<=5; zone++) for (int x=0; x<=10; x++) for (int y=0; y<=10; y++) for (int z=0; z<=10; z++) {
        float g[12], power=0;
        nv_atmos_point_gains(x/10.f,y/10.f,z/10.f,zone,false,g);
        for (int c=0;c<12;c++) { assert(isfinite(g[c]) && g[c]>=0); power+=g[c]*g[c]; }
        near(g[3],0); near(power,1);
    }
    puts("PASS: 12 speaker labels, height beds, objects, timed/interrupted ramps, unchanged metadata, seek, head-lock, ISF fallback, 7,986 power/zone cases");
}
