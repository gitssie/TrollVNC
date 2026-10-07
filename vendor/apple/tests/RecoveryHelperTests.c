#define main FixedRecoveryCommandMain
#include "../src/icloud/TVAppleSearchPartyRecovery.c"
#undef main
#include <assert.h>
#include <stdio.h>
static pid_t Spawn(int status,int stalled){pid_t child=fork();assert(child>=0);if(!child){if(stalled){for(;;)pause();}_exit(status);}return child;}
int main(void){
    assert(TVAppleRecoveryWait(Spawn(0,0),0.5)==0);
    assert(TVAppleRecoveryWait(Spawn(17,0),0.5)==17);
    pid_t child=Spawn(0,1);struct timespec before,after;clock_gettime(CLOCK_MONOTONIC,&before);
    assert(TVAppleRecoveryWait(child,0.05)==75);
    clock_gettime(CLOCK_MONOTONIC,&after);
    assert((after.tv_sec-before.tv_sec)+(after.tv_nsec-before.tv_nsec)/1e9<0.5);
    int status;assert(waitpid(child,&status,WNOHANG)<0&&errno==ECHILD);
    puts("PASS recovery helper: success, nonzero exit, stalled command killed and reaped within deadline");return 0;
}
