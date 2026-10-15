#ifndef TVNC_WIREGUARD_H
#define TVNC_WIREGUARD_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int port;
    int local_port;
    const char* local_host;
} TVNCWGServiceRoute;

char* TVNCWGStartServices(const char* config_json, const char* services_json);
char* TVNCWGStart(const char* config_json, int port);
void TVNCWGStop(void);
void TVNCWGFree(char* value);

#ifdef __cplusplus
}
#endif

#endif