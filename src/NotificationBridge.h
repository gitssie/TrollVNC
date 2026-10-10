#pragma once
#import <Foundation/Foundation.h>
// Returns the adapter's bounded in-memory received history; never a full iOS notification-center query.
NSDictionary *tvNotificationSnapshot(NSString **error);
BOOL tvNotificationsAvailable(void);
