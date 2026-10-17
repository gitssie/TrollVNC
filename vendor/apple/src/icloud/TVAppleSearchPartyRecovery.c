// Fixed-purpose privileged helper. It never accepts a service name or command.
#include <unistd.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <signal.h>
#include <errno.h>
static int TVAppleRecoveryWait(pid_t child,double timeout){
    struct timespec started,now;
    if(clock_gettime(CLOCK_MONOTONIC,&started)!=0){kill(child,SIGKILL);return 71;}
    int status;
    for(;;){
        pid_t result=waitpid(child,&status,WNOHANG);
        if(result==child)return WIFEXITED(status)?WEXITSTATUS(status):71;
        if(result<0&&errno!=EINTR)return 71;
        if(clock_gettime(CLOCK_MONOTONIC,&now)!=0)break;
        if((now.tv_sec-started.tv_sec)+(now.tv_nsec-started.tv_nsec)/1e9>=timeout)break;
        usleep(20000);
    }
    if(kill(child,SIGKILL)!=0&&errno!=ESRCH)return 71;
    // No blocking wait even after SIGKILL; init reaps any delayed child.
    for(int attempt=0;attempt<20;attempt++){
        if(waitpid(child,&status,WNOHANG)==child)break;
        usleep(10000);
    }
    return 75;
}
int main(int argc,char **argv){
    (void)argv;
    if(argc!=1)return 64;
    if(geteuid()!=0)return 77;

    // Resolve the adjacent bootstrap launchctl through the kernel executable path.
    // Dopamine's launchctl is installed beside this helper in the rootless bootstrap.
    char executable[PATH_MAX],path[PATH_MAX];uint32_t size=sizeof(executable);
    if(_NSGetExecutablePath(executable,&size)!=0||!realpath(executable,path))return 80;
    char *end=strrchr(path,'/');if(!end)return 79;
    *end=0;
    // Every parent of the root command must be owned by root and not writable
    // by group/others. Do not trust argv[0], cwd, PATH or caller environment.
    char parent[PATH_MAX];strcpy(parent,path);struct stat directory;
    for(;;){
        if(lstat(parent,&directory)!=0||!S_ISDIR(directory.st_mode)||directory.st_uid!=0||(directory.st_mode&0022))return 81;
        char *slash=strrchr(parent,'/');if(!slash||slash==parent)break;*slash=0;
    }
    if(strlen(path)+sizeof("/launchctl")>sizeof(path))return 79;
    strcat(path,"/launchctl");
    struct stat info;
    if(lstat(path,&info)!=0||!S_ISREG(info.st_mode)||info.st_uid!=0||(info.st_mode&0022))return 82;
    // Clear inherited DYLD/env configuration before executing a root process.
    char *args[]={(char *)path,"kickstart","-k","system/com.apple.icloud.searchpartyd",NULL};
    char *env[]={NULL};
    // Root supervises its own command: mobile cannot kill a launchctl that has
    // changed its real UID to root. Keep this parent's real UID unchanged.
    pid_t child=fork();if(child<0)return 71;
    if(child==0){
        if(setgid(0)!=0||setuid(0)!=0)_exit(78);
        execve(path,args,env);_exit(71);
    }
    return TVAppleRecoveryWait(child,4);
}
