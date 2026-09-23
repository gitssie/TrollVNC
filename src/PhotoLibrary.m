#import "PhotoLibrary.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>

@interface TVPhotoJob : NSObject
@property(nonatomic, copy) NSString *result;
@property(nonatomic, copy) NSString *error;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, strong) NSDate *created;
@end
@implementation TVPhotoJob
@end

static NSMutableDictionary<NSString *, TVPhotoJob *> *tvJobs;
static dispatch_queue_t tvPhotoQueue;

static void tvPhotoInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tvJobs = [NSMutableDictionary dictionary];
        tvPhotoQueue = dispatch_queue_create("com.82flex.trollvnc.photos", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString *tvJSON(id object) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static BOOL tvAuthorized(NSString **error) {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (status == PHAuthorizationStatusAuthorized)
        return YES;
    *error = [NSString stringWithFormat:@"Photos read/write access is unavailable (status %ld)", (long)status];
    return NO;
}

static int tvOpenRemote(const char *root, const char *path) {
    if (!root || !path || path[0] != '/') {
        errno = EINVAL;
        return -1;
    }
    int dir = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (dir < 0)
        return -1;
    const char *part = path + 1;
    for (;;) {
        const char *slash = strchr(part, '/');
        size_t length = slash ? (size_t)(slash - part) : strlen(part);
        if (length == 0 || length > NAME_MAX ||
            (length == 1 && part[0] == '.') ||
            (length == 2 && part[0] == '.' && part[1] == '.')) {
            close(dir);
            errno = EINVAL;
            return -1;
        }
        char component[NAME_MAX + 1];
        memcpy(component, part, length);
        component[length] = '\0';
        int next = openat(dir, component,
                          O_RDONLY | O_NOFOLLOW | (slash ? O_DIRECTORY : 0));
        int saved = errno;
        close(dir);
        if (next < 0) {
            errno = saved;
            return -1;
        }
        if (!slash)
            return next;
        dir = next;
        part = slash + 1;
    }
}

static NSString *tvIncomingReal(void) {
    NSString *rootfs = @"/rootfs/private/var/mobile/Media/DCIM/.MISC/Incoming";
    if (access(rootfs.fileSystemRepresentation, F_OK) == 0)
        return rootfs;
    return @"/private/var/mobile/Media/DCIM/.MISC/Incoming";
}

static BOOL tvImageExtension(NSString *name) {
    return [@[@"png", @"jpg", @"jpeg", @"heic", @"heif"] containsObject:name.pathExtension.lowercaseString];
}

static NSString *tvImport(const char *root, NSString *path, NSString *expected, NSString **error) {
    if (!tvAuthorized(error))
        return nil;
    if (!tvImageExtension(path)) {
        *error = @"Choose a PNG, JPEG, HEIC, or HEIF image";
        return nil;
    }
    int source = tvOpenRemote(root, path.fileSystemRepresentation);
    if (source < 0) {
        *error = [NSString stringWithFormat:@"Cannot open image: %s", strerror(errno)];
        return nil;
    }
    struct stat info;
    if (fstat(source, &info) < 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
        info.st_size > 200 * 1024 * 1024) {
        close(source);
        *error = @"Image must be a regular file of at most 200 MB";
        return nil;
    }
    NSString *folderName = [@"rv-import-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *realFolder = [tvIncomingReal() stringByAppendingPathComponent:folderName];
    NSString *systemFolder = [@"/private/var/mobile/Media/DCIM/.MISC/Incoming" stringByAppendingPathComponent:folderName];
    NSString *fileName = path.lastPathComponent;
    NSString *uploadPrefix = @"rv-upload-";
    NSUInteger suffixAt = uploadPrefix.length + 36;
    if ([fileName hasPrefix:uploadPrefix] && fileName.length > suffixAt + 2 &&
        [[fileName substringWithRange:NSMakeRange(suffixAt, 2)] isEqualToString:@"--"] &&
        [[NSUUID alloc] initWithUUIDString:[fileName substringWithRange:NSMakeRange(uploadPrefix.length, 36)]]) {
        fileName = [fileName substringFromIndex:suffixAt + 2];
    }
    NSString *realFile = [realFolder stringByAppendingPathComponent:fileName];
    NSString *systemFile = [systemFolder stringByAppendingPathComponent:fileName];
    if (mkdir(realFolder.fileSystemRepresentation, 0700) < 0) {
        close(source);
        *error = [NSString stringWithFormat:@"Cannot stage image: %s", strerror(errno)];
        return nil;
    }
    int destination = open(realFile.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    BOOL copied = destination >= 0;
    CC_SHA256_CTX digest;
    CC_SHA256_Init(&digest);
    unsigned char bytes[65536];
    ssize_t count;
    while (copied && (count = read(source, bytes, sizeof(bytes))) > 0) {
        CC_SHA256_Update(&digest, bytes, (CC_LONG)count);
        ssize_t written = 0;
        while (written < count) {
            ssize_t n = write(destination, bytes + written, (size_t)(count - written));
            if (n <= 0) {
                copied = NO;
                break;
            }
            written += n;
        }
    }
    if (copied && count < 0)
        copied = NO;
    if (destination >= 0)
        close(destination);
    close(source);
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(hash, &digest);
    NSMutableString *actual = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(hash); i++)
        [actual appendFormat:@"%02x", hash[i]];
    if (expected.length && ![actual.lowercaseString isEqualToString:expected.lowercaseString]) {
        copied = NO;
        *error = @"Uploaded image hash does not match";
    }
    NSString *result = nil;
    if (!copied && !*error)
        *error = @"Cannot copy image into Photos staging";
    if (copied) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL success = NO;
        __block NSError *changeError = nil;
        __block NSString *assetId = nil;
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetChangeRequest *request = [PHAssetChangeRequest
                creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:systemFile]];
            assetId = request.placeholderForCreatedAsset.localIdentifier;
        } completionHandler:^(BOOL completed, NSError *failure) {
            success = completed;
            changeError = failure;
            dispatch_semaphore_signal(done);
        }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
            *error = @"Photos import timed out";
        } else if (!success || !assetId.length) {
            *error = changeError.localizedDescription ?: @"Photos rejected the image";
        } else if ([PHAsset fetchAssetsWithLocalIdentifiers:@[assetId] options:nil].count != 1) {
            *error = @"Imported photo could not be verified";
        } else {
            result = tvJSON(@{@"assetId": assetId});
        }
    }
    unlink(realFile.fileSystemRepresentation);
    rmdir(realFolder.fileSystemRepresentation);
    // Only a uniquely named upload made for this action is removed. An existing
    // remote file chosen via Import to Photos remains untouched.
    if (result && [path hasPrefix:@"/Media/DCIM/.MISC/Incoming/rv-upload-"] && expected.length)
        tvPhotoCleanupExport(path.UTF8String);
    return result;
}

static NSString *tvList(NSString *requestText, NSString **error) {
    if (!tvAuthorized(error))
        return nil;
    NSDictionary *request = nil;
    NSNumber *offsetNumber = nil;
    if ([requestText hasPrefix:@"{"]) {
        NSData *requestData = [requestText dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = [NSJSONSerialization JSONObjectWithData:requestData options:0 error:nil];
        request = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        offsetNumber = request[@"offset"];
    } else {
        NSInteger offset = requestText.integerValue;
        if (offset >= 0 && [[NSString stringWithFormat:@"%ld", (long)offset] isEqualToString:requestText])
            offsetNumber = @(offset);
    }
    NSString *albumID = [request[@"album"] isKindOfClass:NSString.class] ? request[@"album"] : nil;
    if (![offsetNumber isKindOfClass:NSNumber.class] || offsetNumber.longLongValue < 0 ||
        offsetNumber.longLongValue > INT_MAX || (albumID && albumID.length > 2048)) {
        *error = @"Invalid Photos page";
        return nil;
    }
    NSUInteger offset = offsetNumber.unsignedIntegerValue;
    PHFetchOptions *options = [PHFetchOptions new];
    options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO]];
    options.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", PHAssetMediaTypeImage];
    PHFetchResult<PHAsset *> *assets;
    if (albumID.length) {
        PHFetchResult<PHAssetCollection *> *found = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[albumID] options:nil];
        if (found.count != 1) {
            *error = @"Photo album no longer exists";
            return nil;
        }
        assets = [PHAsset fetchAssetsInAssetCollection:found.firstObject options:options];
    } else {
        assets = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeImage options:options];
    }
    NSMutableArray *albums = [NSMutableArray array];
    for (NSNumber *type in @[@(PHAssetCollectionTypeAlbum), @(PHAssetCollectionTypeSmartAlbum)]) {
        PHFetchResult<PHAssetCollection *> *collections = [PHAssetCollection fetchAssetCollectionsWithType:type.integerValue subtype:PHAssetCollectionSubtypeAny options:nil];
        for (PHAssetCollection *collection in collections) {
            if (!collection.localIdentifier.length || !collection.localizedTitle.length)
                continue;
            [albums addObject:@{@"id": collection.localIdentifier, @"name": collection.localizedTitle}];
            if (albums.count >= 100)
                break;
        }
        if (albums.count >= 100)
            break;
    }
    NSMutableArray *entries = [NSMutableArray array];
    NSUInteger end = MIN(assets.count, offset + 12);
    for (NSUInteger index = offset; index < end; index++) {
        PHAsset *asset = assets[index];
        PHAssetResource *resource = [PHAssetResource assetResourcesForAsset:asset].firstObject;
        PHImageRequestOptions *request = [PHImageRequestOptions new];
        request.synchronous = YES;
        request.networkAccessAllowed = NO;
        request.deliveryMode = PHImageRequestOptionsDeliveryModeFastFormat;
        __block UIImage *thumbnail = nil;
        [[PHImageManager defaultManager] requestImageForAsset:asset
            targetSize:CGSizeMake(64, 64)
            contentMode:PHImageContentModeAspectFill
            options:request
            resultHandler:^(UIImage *image, NSDictionary *info) {
                (void)info;
                thumbnail = image;
            }];
        NSData *jpeg = thumbnail ? UIImageJPEGRepresentation(thumbnail, 0.45) : nil;
        NSString *preview = jpeg.length <= 2400 ? [jpeg base64EncodedStringWithOptions:0] : nil;
        [entries addObject:@{
            @"id": asset.localIdentifier ?: @"",
            @"name": resource.originalFilename ?: @"Photo",
            @"date": @((long long)asset.creationDate.timeIntervalSince1970),
            @"width": @(asset.pixelWidth),
            @"height": @(asset.pixelHeight),
            @"thumbnail": preview ?: @""
        }];
    }
    return tvJSON(@{@"total": @(assets.count), @"offset": @(offset), @"album": albumID ?: [NSNull null], @"albums": albums, @"entries": entries});
}

static NSString *tvExport(NSString *assetId, NSString **error) {
    if (!tvAuthorized(error))
        return nil;
    PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:@[assetId] options:nil];
    if (assets.count != 1) {
        *error = @"Photo no longer exists";
        return nil;
    }
    NSArray<PHAssetResource *> *resources = [PHAssetResource assetResourcesForAsset:assets.firstObject];
    PHAssetResource *original = nil;
    for (PHAssetResource *resource in resources) {
        if (resource.type == PHAssetResourceTypePhoto || resource.type == PHAssetResourceTypeFullSizePhoto) {
            original = resource;
            break;
        }
    }
    if (!original) {
        *error = @"Original photo resource is unavailable";
        return nil;
    }
    NSString *extension = original.originalFilename.pathExtension.lowercaseString;
    if (!tvImageExtension([@"x." stringByAppendingString:extension]))
        extension = @"jpg";
    NSString *name = [NSString stringWithFormat:@"rv-export-%@.%@", NSUUID.UUID.UUIDString, extension];
    NSString *systemPath = [@"/private/var/mobile/Media/DCIM/.MISC/Incoming" stringByAppendingPathComponent:name];
    NSString *realPath = [tvIncomingReal() stringByAppendingPathComponent:name];
    PHAssetResourceRequestOptions *options = [PHAssetResourceRequestOptions new];
    options.networkAccessAllowed = YES;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *exportError = nil;
    [[PHAssetResourceManager defaultManager] writeDataForAssetResource:original
        toFile:[NSURL fileURLWithPath:systemPath]
        options:options
        completionHandler:^(NSError *failure) {
            exportError = failure;
            dispatch_semaphore_signal(done);
        }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC)) != 0) {
        *error = @"Photo export timed out";
    } else if (exportError) {
        *error = exportError.localizedDescription;
    }
    struct stat info;
    if (*error || stat(realPath.fileSystemRepresentation, &info) < 0 ||
        !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > UINT32_MAX) {
        if (!*error)
            *error = @"Exported photo is unavailable or too large";
        unlink(realPath.fileSystemRepresentation);
        return nil;
    }
    return tvJSON(@{
        @"path": [@"/Media/DCIM/.MISC/Incoming" stringByAppendingPathComponent:name],
        @"name": original.originalFilename ?: name,
        @"size": @(info.st_size)
    });
}

static NSString *tvDelete(NSString *requestText, NSString **error) {
    if (!tvAuthorized(error))
        return nil;
    NSArray<NSString *> *ids = @[requestText];
    if ([requestText hasPrefix:@"{"]) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[requestText dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        id values = [parsed isKindOfClass:NSDictionary.class] ? parsed[@"ids"] : nil;
        if (![values isKindOfClass:NSArray.class]) {
            *error = @"Invalid Photos deletion request";
            return nil;
        }
        ids = values;
    }
    if (ids.count == 0 || ids.count > 50) {
        *error = @"Select between 1 and 50 photos";
        return nil;
    }
    NSMutableSet *unique = [NSMutableSet set];
    for (id identifier in ids) {
        if (![identifier isKindOfClass:NSString.class] ||
            [identifier length] == 0 || [identifier length] > 256 ||
            [unique containsObject:identifier]) {
            *error = @"Invalid or duplicate photo ID";
            return nil;
        }
        [unique addObject:identifier];
    }
    PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:ids options:nil];
    if (assets.count != ids.count) {
        *error = @"One or more photos no longer exist";
        return nil;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    __block NSError *changeError = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        [PHAssetChangeRequest deleteAssets:assets];
    } completionHandler:^(BOOL completed, NSError *failure) {
        success = completed;
        changeError = failure;
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC)) != 0) {
        *error = @"Photos deletion timed out; check the iPhone for a confirmation prompt";
        return nil;
    }
    if (!success) {
        *error = changeError.localizedDescription ?: @"Photos did not delete the image";
        return nil;
    }
    if ([PHAsset fetchAssetsWithLocalIdentifiers:ids options:nil].count != 0) {
        *error = @"One or more deleted photos are still in the library";
        return nil;
    }
    return tvJSON(@{@"deleted": ids});
}

int tvPhotoStart(unsigned char op, const char *root, const char *value,
                 const char *expected_sha256, char *token, size_t token_capacity,
                 char *error, size_t error_capacity) {
    tvPhotoInit();
    NSString *input = value ? [NSString stringWithUTF8String:value] : nil;
    NSString *expected = expected_sha256 ? [NSString stringWithUTF8String:expected_sha256] : @"";
    if (!input || !expected || (op != 4 && op != 5 && op != 6 && op != 9) || token_capacity < 37) {
        snprintf(error, error_capacity, "Invalid Photos request");
        return -1;
    }
    if (op == 4 && expected.length && expected.length != 64) {
        snprintf(error, error_capacity, "Invalid image checksum");
        return -1;
    }
    NSString *identifier = NSUUID.UUID.UUIDString;
    TVPhotoJob *job = [TVPhotoJob new];
    job.created = [NSDate date];
    @synchronized(tvJobs) {
        for (NSString *key in tvJobs.allKeys) {
            TVPhotoJob *old = tvJobs[key];
            if ([old.created timeIntervalSinceNow] < -600)
                [tvJobs removeObjectForKey:key];
        }
        if (tvJobs.count >= 64) {
            snprintf(error, error_capacity, "Photos queue is full");
            return -1;
        }
        tvJobs[identifier] = job;
    }
    snprintf(token, token_capacity, "%s", identifier.UTF8String);
    NSString *remoteRoot = root ? [NSString stringWithUTF8String:root] : @"";
    dispatch_async(tvPhotoQueue, ^{
        @autoreleasepool {
            NSString *failure = nil;
            NSString *result = nil;
            if (op == 4)
                result = tvImport(remoteRoot.fileSystemRepresentation, input, expected, &failure);
            else if (op == 5)
                result = tvList(input, &failure);
            else if (op == 6)
                result = tvExport(input, &failure);
            else
                result = tvDelete(input, &failure);
            @synchronized(job) {
                job.result = result;
                job.error = failure ?: (result ? nil : @"Photos operation failed");
                job.finished = YES;
            }
        }
    });
    return 0;
}

int tvPhotoPoll(const char *token, char **payload, char **error) {
    tvPhotoInit();
    NSString *identifier = token ? [NSString stringWithUTF8String:token] : nil;
    TVPhotoJob *job = nil;
    @synchronized(tvJobs) {
        job = tvJobs[identifier];
    }
    if (!job) {
        *error = strdup("Photos job not found");
        return -1;
    }
    @synchronized(job) {
        if (!job.finished)
            return 1;
        if (job.error) {
            *error = strdup(job.error.UTF8String);
            return -1;
        }
        *payload = strdup(job.result.UTF8String);
        return 0;
    }
}

int tvPhotoCleanupExport(const char *remote_path) {
    NSString *path = remote_path ? [NSString stringWithUTF8String:remote_path] : nil;
    NSString *prefix = @"/Media/DCIM/.MISC/Incoming/";
    if (!path || ![path hasPrefix:prefix]) {
        errno = EINVAL;
        return -1;
    }
    NSString *name = [path substringFromIndex:prefix.length];
    BOOL generated = [name hasPrefix:@"rv-export-"] || [name hasPrefix:@"rv-upload-"];
    NSUInteger suffixAt = 10 + 36;
    NSString *suffix = name.length > suffixAt ? [name substringFromIndex:suffixAt] : @"";
    BOOL validSuffix = ([suffix hasPrefix:@"."] && tvImageExtension(name)) ||
                       ([suffix hasPrefix:@"--"] && suffix.length > 2 && tvImageExtension(name));
    if (!generated || name.length <= suffixAt ||
        ![[NSUUID alloc] initWithUUIDString:[name substringWithRange:NSMakeRange(10, 36)]] ||
        !validSuffix || [name containsString:@"/"] || [name containsString:@"\\"] ||
        strlen(name.fileSystemRepresentation) > NAME_MAX) {
        errno = EINVAL;
        return -1;
    }
    int dir = open(tvIncomingReal().fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (dir < 0)
        return -1;
    int result = unlinkat(dir, name.fileSystemRepresentation, 0);
    int saved = errno;
    close(dir);
    errno = saved;
    return result;
}
