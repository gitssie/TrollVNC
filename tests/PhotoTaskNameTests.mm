#import "PhotoTaskName.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        NSString *uuid = @"12345678-1234-4234-8234-123456789abc";
        for (NSString *suffix in @[@"--original--photo.JPG", @"-0123456789abcdef--original--photo.JPG"]) {
            NSString *name = [NSString stringWithFormat:@"rv-upload-%@%@", uuid, suffix];
            NSString *task = nil;
            assert([tvPhotoUploadOriginalName(name, &task) isEqualToString:@"original--photo.JPG"]);
            assert([task isEqualToString:uuid]);
            assert(tvPhotoGeneratedNameCanCleanup(name));
        }
        for (NSString *suffix in @[@"-0123456789abcdeg--photo.jpg", @"-0123456789abcde--photo.jpg",
                                   @"-0123456789abcdef0--photo.jpg", @"--", @"-0123456789abcdef--",
                                   @"--../photo.jpg", @"--dir\\photo.jpg", @"--.", @"--.."]) {
            NSString *name = [NSString stringWithFormat:@"rv-upload-%@%@", uuid, suffix];
            assert(!tvPhotoUploadOriginalName(name, NULL));
            assert(!tvPhotoGeneratedNameCanCleanup(name));
        }
        assert(tvPhotoGeneratedNameCanCleanup([NSString stringWithFormat:@"rv-export-%@.heic", uuid]));
        assert(tvPhotoGeneratedNameCanCleanup([NSString stringWithFormat:@"rv-export-%@--photo.png", uuid]));
        for (NSString *name in @[@"rv-upload-invalid--photo.jpg", @"photo.jpg", @"rv-export-invalid.jpg", @"rv-upload-"]) {
            assert(!tvPhotoUploadOriginalName(name, NULL));
            assert(!tvPhotoGeneratedNameCanCleanup(name));
        }
        assert(!tvPhotoGeneratedNameCanCleanup([NSString stringWithFormat:@"rv-upload-%@--script.txt", uuid]));
        NSString *longName = [@"x" stringByPaddingToLength:256 withString:@"x" startingAtIndex:0];
        assert(!tvPhotoGeneratedNameCanCleanup([NSString stringWithFormat:@"rv-upload-%@--%@.jpg", uuid, longName]));
        puts("Photo task name tests passed");
    }
    return 0;
}
