// Host-only test infrastructure. Never link this helper into the iOS app.
// Xcode 27's DeviceHub does not use the old Simulator keyboard preferences.
// CoreSimulator has no public simctl command for this per-device setting, so
// isolate its private host API here and fail closed if any signature changes.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

static void fail(NSString *message) {
    fprintf(stderr, "Simulator keyboard configuration failed: %s\n", message.UTF8String);
    fprintf(stderr, "Check the selected Xcode and update this host helper if its CoreSimulator API changed.\n");
    exit(1);
}

static void checkSignature(id target, SEL selector, const char *result,
                           NSArray<NSString *> *arguments) {
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType, result) != 0 ||
        signature.numberOfArguments != arguments.count + 2) {
        fail([NSString stringWithFormat:@"Unavailable or incompatible method %@", NSStringFromSelector(selector)]);
    }
    for (NSUInteger index = 0; index < arguments.count; index++) {
        if (strcmp([signature getArgumentTypeAtIndex:index + 2], arguments[index].UTF8String) != 0) {
            fail([NSString stringWithFormat:@"Incompatible argument %lu for %@",
                  (unsigned long)index, NSStringFromSelector(selector)]);
        }
    }
}

static id getObject(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    checkSignature(target, selector, @encode(id), @[]);
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        @try {
            // Validate all arguments before loading CoreSimulator or contacting its service.
            if (argc != 4) {
                fail(@"Usage: configure-ios-simulator-keyboard <developer-dir> <UDID> <expected-name>");
            }
            NSString *developerDir = [NSString stringWithUTF8String:argv[1]];
            NSUUID *expectedUDID = [[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:argv[2]]];
            NSString *expectedName = [NSString stringWithUTF8String:argv[3]];
            if (!expectedUDID || expectedName.length == 0 ||
                [expectedName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
                fail(@"A valid simulator UDID and nonempty expected name (without control characters) are required.");
            }
            BOOL isDirectory = NO;
            NSFileManager *files = NSFileManager.defaultManager;
            if (!developerDir.isAbsolutePath ||
                ![files fileExistsAtPath:developerDir isDirectory:&isDirectory] || !isDirectory ||
                ![files isExecutableFileAtPath:[developerDir stringByAppendingPathComponent:@"usr/bin/simctl"]]) {
                fail(@"developer-dir must be the selected Xcode developer directory containing usr/bin/simctl.");
            }

            // Apple's shared host framework, not an Xcode installation-specific path.
            if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) {
                fail([NSString stringWithFormat:@"Cannot load Apple's CoreSimulator framework: %s", dlerror()]);
            }
            Class contextClass = NSClassFromString(@"SimServiceContext");
            Class deviceClass = NSClassFromString(@"SimDevice");
            if (!contextClass || !deviceClass) {
                fail(@"CoreSimulator service/device classes are unavailable.");
            }
            SEL serviceSelector = NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:");
            checkSignature(contextClass, serviceSelector, @encode(id), @[@(@encode(id)), @(@encode(NSError * __autoreleasing *))]);
            NSError *error = nil;
            id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
                contextClass, serviceSelector, developerDir, &error);
            if (!context || error) {
                fail([NSString stringWithFormat:@"Cannot open service context for %@: %@", developerDir, error]);
            }
            SEL setSelector = NSSelectorFromString(@"defaultDeviceSetWithError:");
            checkSignature(context, setSelector, @encode(id), @[@(@encode(NSError * __autoreleasing *))]);
            id deviceSet = ((id (*)(id, SEL, NSError **))objc_msgSend)(context, setSelector, &error);
            if (!deviceSet || error) {
                fail([NSString stringWithFormat:@"Cannot open default simulator device set: %@", error]);
            }
            NSArray *devices = getObject(deviceSet, @"availableDevices");
            if (![devices isKindOfClass:NSArray.class]) {
                fail(@"CoreSimulator did not return an available-device array.");
            }
            id target = nil;
            NSUInteger matches = 0;
            for (id device in devices) {
                if (![device isKindOfClass:deviceClass]) {
                    fail(@"CoreSimulator returned an unexpected device object.");
                }
                NSUUID *udid = getObject(device, @"UDID");
                if (![udid isKindOfClass:NSUUID.class]) {
                    fail(@"CoreSimulator returned an invalid device UDID.");
                }
                if ([udid isEqual:expectedUDID]) {
                    target = device;
                    matches++;
                }
            }
            if (matches != 1) {
                fail([NSString stringWithFormat:@"Expected exactly one SimDevice with UDID %@; found %lu.",
                      expectedUDID.UUIDString, (unsigned long)matches]);
            }
            NSString *name = getObject(target, @"name");
            NSString *state = getObject(target, @"stateString");
            if (![name isEqual:expectedName] || ![state isEqual:@"Booted"]) {
                fail([NSString stringWithFormat:@"Refusing %@: expected name '%@' and Booted, got '%@' / '%@'.",
                      expectedUDID.UUIDString, expectedName, name, state]);
            }
            SEL setter = NSSelectorFromString(@"setHardwareKeyboardEnabled:keyboardType:error:");
            checkSignature(target, setter, @encode(BOOL),
                           @[@(@encode(BOOL)), @(@encode(unsigned char)), @(@encode(NSError * __autoreleasing *))]);
            // The only mutator: keyboardType is an unsigned char, not an object.
            error = nil;
            BOOL success = ((BOOL (*)(id, SEL, BOOL, unsigned char, NSError **))objc_msgSend)(
                target, setter, NO, (unsigned char)0, &error);
            if (!success || error) {
                fail([NSString stringWithFormat:@"Cannot disable hardware keyboard for %@ (%@): %@",
                      name, expectedUDID.UUIDString, error]);
            }
            fprintf(stderr, "Disabled hardware keyboard for %s (%s).\n",
                    name.UTF8String, expectedUDID.UUIDString.UTF8String);
            return 0;
        } @catch (NSException *exception) {
            fail([NSString stringWithFormat:@"CoreSimulator exception: %@", exception]);
        }
    }
    return 1;
}
