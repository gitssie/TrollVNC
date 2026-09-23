#include "FileManagement.h"
#include "PhotoLibrary.h"

#include <arpa/inet.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <rfb/rfb.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Wire protocol v1:
// SetEncodings includes C0A1F17E. Server replies [137, version=1, flags, 0].
// Request: [137, op, reserved:u16, id:u32, pathLen:u16, destLen:u16, paths].
// Reply:   [138, op, status, id:u32, messageLen:u16, message].
// op 1 = delete; 2 = mkdir; 3 = rename; 4 = import photo; 5 = list photos;
// 6 = export original; 7 = poll job; 8 = remove completed export;
// 10 = atomically replace a regular file; 11 = SHA-256 of a regular file.
// Paths use the same /-relative-to-mobile-home namespace as TightVNC FTP.
#define TV_FILE_ENCODING ((int)0xC0A1F17E)
#define TV_FILE_REQUEST 137
#define TV_FILE_REPLY 138
#define TV_FILE_MAX_PATH 4096

static int tvFileEncodings[] = {TV_FILE_ENCODING, 0};
static char tvFileRoot[PATH_MAX] = "/var/mobile";

static rfbBool tvFileNewClient(rfbClientPtr cl, void **data) {
    (void)cl;
    *data = NULL;
    return TRUE;
}

static rfbBool tvFileWrite(rfbClientPtr cl, const unsigned char *bytes, int length) {
    rfbBool ok;
    pthread_mutex_lock(&cl->sendMutex);
    ok = rfbWriteExact(cl, (const char *)bytes, length) >= 0;
    pthread_mutex_unlock(&cl->sendMutex);
    return ok;
}

static rfbBool tvFileEnable(rfbClientPtr cl, void **data, int encoding) {
    if (encoding == 0) {
        *data = NULL;
        return TRUE;
    }
    if (encoding != TV_FILE_ENCODING)
        return FALSE;
    *data = (void *)1;
    const unsigned char message[] = {TV_FILE_REQUEST, 1, 255, 0};
    return tvFileWrite(cl, message, sizeof(message));
}

static int tvFileParent(const char *path, char *leaf, size_t leaf_size) {
    if (!path || path[0] != '/') {
        errno = EINVAL;
        return -1;
    }
    int dir = open(tvFileRoot, O_RDONLY | O_DIRECTORY);
    if (dir < 0)
        return -1;
    const char *part = path + 1;
    for (;;) {
        const char *slash = strchr(part, '/');
        size_t len = slash ? (size_t)(slash - part) : strlen(part);
        if (len == 0 || len > NAME_MAX || (len == 1 && part[0] == '.') ||
            (len == 2 && part[0] == '.' && part[1] == '.')) {
            errno = EINVAL;
            close(dir);
            return -1;
        }
        if (!slash) {
            if (len + 1 > leaf_size) {
                errno = ENAMETOOLONG;
                close(dir);
                return -1;
            }
            memcpy(leaf, part, len);
            leaf[len] = '\0';
            return dir;
        }
        char component[NAME_MAX + 1];
        memcpy(component, part, len);
        component[len] = '\0';
        int next = openat(dir, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int saved = errno;
        close(dir);
        if (next < 0) {
            errno = saved;
            return -1;
        }
        dir = next;
        part = slash + 1;
    }
}

static int tvFileOperate(unsigned char op, const char *path, const char *destination) {
    char leaf[NAME_MAX + 1];
    int dir = tvFileParent(path, leaf, sizeof(leaf));
    if (dir < 0)
        return -1;
    int result = -1;
    if (op == 1) {
        struct stat info;
        if (fstatat(dir, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0)
            result = unlinkat(dir, leaf, S_ISDIR(info.st_mode) ? AT_REMOVEDIR : 0);
    } else if (op == 2) {
        result = mkdirat(dir, leaf, 0755);
    } else if ((op == 3 || op == 10) && destination) {
        char dest_leaf[NAME_MAX + 1];
        int dest_dir = tvFileParent(destination, dest_leaf, sizeof(dest_leaf));
        if (dest_dir >= 0) {
            if (op == 10) {
                struct stat source_info, dest_info, source_parent, dest_parent;
                if (fstat(dir, &source_parent) == 0 && fstat(dest_dir, &dest_parent) == 0 &&
                    source_parent.st_dev == dest_parent.st_dev && source_parent.st_ino == dest_parent.st_ino &&
                    fstatat(dir, leaf, &source_info, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(source_info.st_mode) &&
                    fstatat(dest_dir, dest_leaf, &dest_info, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(dest_info.st_mode))
                    result = renameat(dir, leaf, dest_dir, dest_leaf);
                else if (errno == 0) errno = EINVAL;
            } else result = renameatx_np(dir, leaf, dest_dir, dest_leaf, RENAME_EXCL);
            int dest_saved = errno;
            close(dest_dir);
            errno = dest_saved;
        }
    } else {
        errno = EINVAL;
    }
    int saved = errno;
    close(dir);
    errno = saved;
    return result;
}

static int tvFileHash(const char *path, char digest[65]) {
    char leaf[NAME_MAX + 1];
    int dir = tvFileParent(path, leaf, sizeof(leaf));
    if (dir < 0) return -1;
    int file = openat(dir, leaf, O_RDONLY | O_NOFOLLOW);
    int saved = errno;
    close(dir);
    if (file < 0) { errno = saved; return -1; }
    struct stat info;
    int result = -1;
    if (fstat(file, &info) == 0 && S_ISREG(info.st_mode)) {
        CC_SHA256_CTX context;
        CC_SHA256_Init(&context);
        unsigned char bytes[65536];
        ssize_t count;
        while ((count = read(file, bytes, sizeof(bytes))) > 0)
            CC_SHA256_Update(&context, bytes, (CC_LONG)count);
        if (count == 0) {
            unsigned char hash[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256_Final(hash, &context);
            for (size_t i = 0; i < sizeof(hash); ++i) snprintf(digest + i * 2, 3, "%02x", hash[i]);
            digest[64] = '\0';
            result = 0;
        }
    } else if (errno == 0) errno = EINVAL;
    saved = errno;
    close(file);
    errno = saved;
    return result;
}

static void tvFileReply(rfbClientPtr cl, unsigned char op, unsigned char status,
                        const unsigned char *id, const char *message) {
    size_t length = message ? strlen(message) : 0;
    if (length > 60000)
        length = 60000;
    unsigned char *reply = calloc(9 + length, 1);
    if (!reply)
        return;
    reply[0] = TV_FILE_REPLY;
    reply[1] = op;
    reply[2] = status;
    memcpy(reply + 3, id, 4);
    reply[7] = (unsigned char)(length >> 8);
    reply[8] = (unsigned char)length;
    if (length)
        memcpy(reply + 9, message, length);
    tvFileWrite(cl, reply, (int)(9 + length));
    free(reply);
}

static rfbBool tvFileMessage(rfbClientPtr cl, void *data, const rfbClientToServerMsg *message) {
    if (message->type != TV_FILE_REQUEST)
        return FALSE;
    // Without capability negotiation this message is invalid, but consume it
    // and return a failure instead of affecting any filesystem state.
    unsigned char header[11];
    if (rfbReadExact(cl, (char *)header, sizeof(header)) <= 0)
        return TRUE;
    unsigned char op = header[0];
    uint32_t id;
    uint16_t path_len;
    uint16_t destination_len;
    memcpy(&id, header + 3, sizeof(id));
    memcpy(&path_len, header + 7, sizeof(path_len));
    memcpy(&destination_len, header + 9, sizeof(destination_len));
    path_len = ntohs(path_len);
    destination_len = ntohs(destination_len);
    if (path_len == 0 || path_len > TV_FILE_MAX_PATH || header[1] != 0 || header[2] != 0 ||
        destination_len > TV_FILE_MAX_PATH || op < 1 || op > 11 ||
        ((op == 3 || op == 10) && destination_len == 0) ||
        (op != 3 && op != 4 && op != 10 && destination_len != 0) ||
        (op == 4 && destination_len != 0 && destination_len != 64)) {
        rfbCloseClient(cl);
        return TRUE;
    }
    char path[TV_FILE_MAX_PATH + 1];
    if (rfbReadExact(cl, path, path_len) <= 0)
        return TRUE;
    path[path_len] = '\0';
    char destination[TV_FILE_MAX_PATH + 1];
    if (destination_len > 0 && rfbReadExact(cl, destination, destination_len) <= 0)
        return TRUE;
    destination[destination_len] = '\0';
    if (data != (void *)1 || memchr(path, '\0', path_len) ||
        memchr(destination, '\0', destination_len)) {
        tvFileReply(cl, op, 1, (unsigned char *)&id, "File operation is unavailable");
        return TRUE;
    }
    if (op <= 3 || op == 10) {
        errno = EACCES;
        int result = cl->viewOnly ? -1 : tvFileOperate(op, path, destination_len ? destination : NULL);
        tvFileReply(cl, op, result == 0 ? 0 : 1, (unsigned char *)&id,
                    result == 0 ? "" : strerror(errno));
    } else if (op == 11) {
        char digest[65];
        int result = tvFileHash(path, digest);
        tvFileReply(cl, op, result == 0 ? 0 : 1, (unsigned char *)&id,
                    result == 0 ? digest : strerror(errno));
    } else if (op <= 6 || op == 9) {
        if (cl->viewOnly && (op == 4 || op == 9)) {
            tvFileReply(cl, op, 1, (unsigned char *)&id, "Photos changes are disabled in view-only mode");
            return TRUE;
        }
        char token[40] = {0};
        char error[256] = {0};
        int result = tvPhotoStart(op, tvFileRoot, path, destination,
                                  token, sizeof(token), error, sizeof(error));
        tvFileReply(cl, op, result == 0 ? 2 : 1, (unsigned char *)&id,
                    result == 0 ? token : error);
    } else if (op == 7) {
        char *payload = NULL;
        char *error = NULL;
        int result = tvPhotoPoll(path, &payload, &error);
        tvFileReply(cl, op, result == 0 ? 0 : (result == 1 ? 2 : 1),
                    (unsigned char *)&id, result == 0 ? payload : error);
        free(payload);
        free(error);
    } else {
        if (cl->viewOnly) {
            tvFileReply(cl, op, 1, (unsigned char *)&id, "Cleanup is disabled in view-only mode");
            return TRUE;
        }
        int result = tvPhotoCleanupExport(path);
        tvFileReply(cl, op, result == 0 ? 0 : 1, (unsigned char *)&id,
                    result == 0 ? "" : strerror(errno));
    }
    return TRUE;
}

static rfbProtocolExtension tvFileExtension = {
    .newClient = tvFileNewClient,
    .pseudoEncodings = tvFileEncodings,
    .enablePseudoEncoding = tvFileEnable,
    .handleMessage = tvFileMessage,
};

void tvRegisterFileManagement(const char *root) {
    if (!root || strlen(root) >= sizeof(tvFileRoot))
        return;
    strcpy(tvFileRoot, root);
    rfbRegisterProtocolExtension(&tvFileExtension);
}
void tvUnregisterFileManagement(void) { rfbUnregisterProtocolExtension(&tvFileExtension); }
