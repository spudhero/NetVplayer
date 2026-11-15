// Research-only direct libbluray control. No decoder, UI, or menu acceptance claim.
#include <libbluray/bluray.h>
#include <libbluray/keys.h>
#include <libbluray/overlay.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned overlays[2];
static void overlay(void *opaque, const BD_OVERLAY *o) {
    (void)opaque;
    if (o && o->plane < 2) overlays[o->plane]++;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) return 2;
    int major, minor, micro;
    bd_get_version(&major, &minor, &micro);
    BLURAY *bd=bd_open(argv[1], NULL);
    if (!bd) return 3;
    const BLURAY_DISC_INFO *d=bd_get_disc_info(bd);
    if (!d) { bd_close(bd); return 4; }
    printf("{\"library\":\"%d.%d.%d\",\"blurayDetected\":%d,\"aacs\":%d,\"bdplus\":%d,"
           "\"hdmvTitles\":%u,\"bdjTitles\":%u,\"firstPlay\":%d,\"topMenu\":%d,\"titles\":[",
           major,minor,micro,d->bluray_detected,d->aacs_detected,d->bdplus_detected,
           d->num_hdmv_titles,d->num_bdj_titles,d->first_play_supported,d->top_menu_supported);
    unsigned count=bd_get_titles(bd,TITLES_ALL,0);
    for(unsigned i=0;i<count;i++) {
        BLURAY_TITLE_INFO *t=bd_get_title_info(bd,i,0);
        if(i) putchar(',');
        if(!t) { printf("null");continue; }
        printf("{\"playlist\":%u,\"durationTicks\":%llu,\"angles\":%u,\"clips\":[",
               t->playlist,(unsigned long long)t->duration,t->angle_count);
        for(unsigned j=0;j<t->clip_count;j++) {
            BLURAY_CLIP_INFO *c=&t->clips[j];
            if(j) putchar(',');
            printf("{\"id\":\"%.5s\",\"inTime\":%llu,\"outTime\":%llu,\"audioPIDs\":[",
                   c->clip_id,(unsigned long long)c->in_time,(unsigned long long)c->out_time);
            for(unsigned k=0;k<c->audio_stream_count;k++) printf("%s%u",k?",":"",c->audio_streams[k].pid);
            printf("],\"pgPIDs\":[");
            for(unsigned k=0;k<c->pg_stream_count;k++) printf("%s%u",k?",":"",c->pg_streams[k].pid);
            printf("],\"igPIDs\":[");
            for(unsigned k=0;k<c->ig_stream_count;k++) printf("%s%u",k?",":"",c->ig_streams[k].pid);
            printf("]}");
        }
        printf("],\"chaptersTicks\":[");
        for(unsigned j=0;j<t->chapter_count;j++) printf("%s%llu",j?",":"",(unsigned long long)t->chapters[j].start);
        printf("]}");bd_free_title_info(t);
    }
    printf("],\"navigation\":[");
    if(argc==3 && !strcmp(argv[2],"authored") && !d->aacs_detected && !d->bdplus_detected && !d->num_bdj_titles) {
        bd_get_event(bd,NULL);bd_register_overlay_proc(bd,NULL,overlay);
        int started=bd_play(bd), emitted=0, activated=0;
        unsigned char buffer[6144];
        for(int i=0;started && i<20000;i++) {
            BD_EVENT e={0};int n=bd_read_ext(bd,buffer,sizeof(buffer),&e);
            if(e.event && emitted<256) {
                printf("%s{\"event\":%u,\"param\":%u,\"tellTime\":%llu}",emitted++?",":"",e.event,e.param,(unsigned long long)bd_tell_time(bd));
            }
            if(e.event==BD_EVENT_STILL_TIME && !activated) {
                // Activate chapter 2 in the original authored fixture. No
                // bd_seek or mpv timeline is involved in this control run.
                bd_user_input(bd,-1,BD_VK_DOWN);bd_user_input(bd,-1,BD_VK_ENTER);activated=1;
            }
            if(activated && e.event==BD_EVENT_SEEK) break;
            if(n<0) break;
        }
    }
    printf("],\"overlayCallbacks\":[%u,%u],\"decodedVideo\":false}\n",overlays[0],overlays[1]);
    bd_close(bd);return 0;
}
