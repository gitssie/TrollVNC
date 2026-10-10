#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/wait.h>
#include <signal.h>
struct LSDIdentity {pid_t pid;struct timeval start;};

// One operation, no network service or keychain authority. Explicit physical file
// and exact vendor/application membership; this worker refuses shared vendors.
static BOOL SetRecord(NSString *path, NSString *vendor, NSString *bundle, NSString *old, NSString *next) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation,&st)!=0 || !S_ISREG(st.st_mode)) return NO;
    NSData *input=[NSData dataWithContentsOfFile:path];
    NSMutableDictionary *plist=[NSPropertyListSerialization propertyListWithData:input options:NSPropertyListMutableContainersAndLeaves format:NULL error:NULL];
    if (![plist isKindOfClass:NSMutableDictionary.class])return NO;
    NSMutableDictionary *record=plist[@"LSVendors"][vendor];
    if (![record[@"LSApplications"] isEqual:@[bundle]] || ![record[@"LSVendorIdentifier"] isEqual:old])return NO;
    record[@"LSVendorIdentifier"]=next;
    NSData *output=[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if(!output)return NO;
    NSString *template=[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".pxas-idfv-XXXXXX"];
    char *temp=strdup(template.fileSystemRepresentation);int fd=mkstemp(temp);if(fd<0){free(temp);return NO;}
    BOOL ok=fchown(fd,st.st_uid,st.st_gid)==0&&fchmod(fd,st.st_mode&07777)==0;
    size_t offset=0;while(ok&&offset<output.length){ssize_t n=write(fd,(const char *)output.bytes+offset,output.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0)ok=NO;else offset+=(size_t)n;}
    if(ok)ok=fsync(fd)==0;close(fd);
    struct stat current;
    if(ok)ok=lstat(path.fileSystemRepresentation,&current)==0&&current.st_dev==st.st_dev&&current.st_ino==st.st_ino&&
        [[NSData dataWithContentsOfFile:path] isEqual:input];
    if(ok)ok=rename(temp,path.fileSystemRepresentation)==0;
    if(!ok)unlink(temp);free(temp);return ok;
}
static int Run(int argc,const char **argv,int notify){@autoreleasepool{
    BOOL checkOnly = argc == 7 && strcmp(argv[1], "--check") == 0;
    if((argc != 6 && !checkOnly)||getuid()!=0)return 64;
    int offset = checkOnly ? 1 : 0;
    NSString *path=@(argv[1+offset]),*vendor=@(argv[2+offset]),*bundle=@(argv[3+offset]),*old=@(argv[4+offset]),*next=@(argv[5+offset]);
    char *resolved=realpath(path.fileSystemRepresentation,NULL);if(!resolved)return 65;
    BOOL canonical=[path isEqual:@(resolved)];free(resolved);
    if(!canonical||![path hasPrefix:@"/private/var/containers/Shared/SystemGroup/"]||
        ![path hasSuffix:@"/Library/Caches/com.apple.lsdidentifiers.plist"]||[path containsString:@".."]||
        ![[NSUUID alloc] initWithUUIDString:old]||![[NSUUID alloc] initWithUUIDString:next]||vendor.length==0||bundle.length==0)return 65;
    NSDictionary *plist=[NSDictionary dictionaryWithContentsOfFile:path];
    NSDictionary *record=plist[@"LSVendors"][vendor];
    if (![record[@"LSApplications"] isEqual:@[bundle]] || ![record[@"LSVendorIdentifier"] isEqual:old]) return 67;
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};size_t size=0;
    if(sysctl(mib,4,NULL,&size,NULL,0)!=0)return 66;
    NSMutableData *data=[NSMutableData dataWithLength:size+sizeof(struct kinfo_proc)*64];size=data.length;
    if(sysctl(mib,4,data.mutableBytes,&size,NULL,0)!=0)return 66;
    int (*processPath)(int,void *,uint32_t)=dlsym(RTLD_DEFAULT,"proc_pidpath");if(!processPath)return 66;
    const struct kinfo_proc *processes=data.bytes;pid_t lsd=0;struct LSDIdentity identity={0};
    for(NSUInteger i=0;i<size/sizeof(struct kinfo_proc);i++){
        if(processes[i].kp_eproc.e_ucred.cr_uid!=501||strcmp(processes[i].kp_proc.p_comm,"lsd")!=0)continue;
        char executable[4096]={0};if(processPath(processes[i].kp_proc.p_pid,executable,sizeof(executable))<=0||strcmp(executable,"/usr/libexec/lsd")!=0)return 66;
        if(lsd!=0)return 66;lsd=processes[i].kp_proc.p_pid;identity.pid=lsd;identity.start=processes[i].kp_proc.p_starttime;
    }
    if(lsd<=0)return 66;
    if(checkOnly)return 0;
    if(write(notify,&identity,sizeof(identity))!=sizeof(identity))return 66;
    if(kill(lsd,SIGSTOP)!=0)return 66;
    BOOL ok=NO;
    @try{ok=SetRecord(path,vendor,bundle,old,next);}
    @finally{if(ok){if(kill(lsd,SIGKILL)!=0){kill(lsd,SIGCONT);ok=NO;}}else kill(lsd,SIGCONT);}
    return ok?0:67;
}return 0;}

static void Resume(struct LSDIdentity identity) {
    if(identity.pid<=0)return;
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,identity.pid};struct kinfo_proc p;size_t size=sizeof(p);
    if(sysctl(mib,4,&p,&size,NULL,0)!=0 || size!=sizeof(p) || p.kp_eproc.e_ucred.cr_uid!=501 ||
       p.kp_proc.p_starttime.tv_sec!=identity.start.tv_sec || p.kp_proc.p_starttime.tv_usec!=identity.start.tv_usec)return;
    int (*pathfn)(int,void *,uint32_t)=dlsym(RTLD_DEFAULT,"proc_pidpath");char path[4096]={0};
    if(pathfn && pathfn(identity.pid,path,sizeof(path))>0 && strcmp(path,"/usr/libexec/lsd")==0)kill(identity.pid,SIGCONT);
}
static int Supervise(int (^run)(int),void (^resume)(struct LSDIdentity),NSTimeInterval timeout,pid_t owner){@autoreleasepool{
    int pipefd[2];if(pipe(pipefd)!=0)return 66;
    pid_t child=fork();if(child<0){close(pipefd[0]);close(pipefd[1]);return 66;}
    if(child==0){close(pipefd[0]);int result=run(pipefd[1]);close(pipefd[1]);_exit(result);}
    close(pipefd[1]);
    signal(SIGTERM,SIG_IGN);signal(SIGHUP,SIG_IGN);signal(SIGINT,SIG_IGN);
    if(fcntl(pipefd[0],F_SETFL,O_NONBLOCK)!=0){kill(child,SIGKILL);waitpid(child,NULL,0);close(pipefd[0]);return 66;}
    struct LSDIdentity identity={0};NSUInteger received=0;int status=0;BOOL success=NO;int exitCode=66;
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;
    for(;;){
        ssize_t n=read(pipefd[0],((char *)&identity)+received,sizeof(identity)-received);if(n>0)received+=(NSUInteger)n;
        pid_t result=waitpid(child,&status,WNOHANG);
        if(result==child){if(WIFEXITED(status))exitCode=WEXITSTATUS(status);success=exitCode==0;break;}
        if((result<0&&errno!=EINTR) || NSProcessInfo.processInfo.systemUptime>=deadline || getppid()!=owner){
            kill(child,SIGKILL);while(waitpid(child,&status,0)<0&&errno==EINTR){}break;
        }
        usleep(10000);
    }
    // Drain a final identity notification even if the child exited between polls.
    if(received<sizeof(identity)){ssize_t n=read(pipefd[0],((char *)&identity)+received,sizeof(identity)-received);if(n>0)received+=(NSUInteger)n;}
    close(pipefd[0]);if(!success && received==sizeof(identity))resume(identity);
    return exitCode;
}}

int main(int argc,const char **argv) {
    return Supervise(^(int notify){return Run(argc,argv,notify);},^(struct LSDIdentity identity){Resume(identity);},8,getppid());
}
