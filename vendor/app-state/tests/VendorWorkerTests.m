#define main TVASVendorMain
#import "../cli/VendorWorker.m"
#undef main
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d\n",__LINE__);exit(1);}}while(0)
int main(){@autoreleasepool{
    __block BOOL resumed=NO;__block pid_t childPID=0;
    int status=Supervise(^(int fd){(void)fd;return 0;},^(struct LSDIdentity identity){(void)identity;resumed=YES;},.2,getppid());
    CHECK(status==0 && !resumed);
    NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
    status=Supervise(^(int fd){struct LSDIdentity id={0};id.pid=getpid();write(fd,&id,sizeof(id));for(;;)usleep(10000);return 0;},^(struct LSDIdentity id){resumed=YES;childPID=id.pid;},.2,getppid());
    CHECK(status==66 && resumed && childPID>0 && NSProcessInfo.processInfo.systemUptime-start<2 && kill(childPID,0)<0);
    resumed=NO;
    status=Supervise(^(int fd){struct LSDIdentity id={0};id.pid=getpid();write(fd,&id,sizeof(id));return 67;},^(struct LSDIdentity id){CHECK(id.pid>0);resumed=YES;},.2,getppid());
    CHECK(status==67 && resumed);
    // Simulate loss of requesting parent: no privileged work survives acknowledgement.
    resumed=NO;start=NSProcessInfo.processInfo.systemUptime;
    status=Supervise(^(int fd){struct LSDIdentity id={0};id.pid=getpid();write(fd,&id,sizeof(id));for(;;)usleep(10000);return 0;},^(struct LSDIdentity id){(void)id;resumed=YES;},1,-1);
    CHECK(status==66 && NSProcessInfo.processInfo.systemUptime-start<.5);
    puts("IDFV helper supervision timeout/parent loss/reap/recovery tests PASS (no lsd touched)");
}return 0;}
