// MBMetalShims.mm — implementations of the macOS-only Metal surface for iOS.
// Compiled into MetalBridgeKit (ARC, iOS build). See MBMetalShims.h for the contract.

#import "MBMetalShims.h"
// The header maps caller call-sites onto mb-named selectors; this file implements them by their
// mb names (and displaySyncEnabled by its real name, which nothing shadows because the runtime
// class has no such method on iOS).
#undef displaySyncEnabled
#undef newResidencySetWithDescriptor
#undef addResidencySet
#undef mathMode

#if !TARGET_OS_OSX

#import <objc/message.h>
#import <mach/mach_time.h>
#import <stdlib.h>
#import <pthread.h>

#pragma mark - Shared helpers

static double MBSecondsPerUnit(void) {
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	return (double)tb.numer / (double)tb.denom / 1e9;
}

static uint32_t MBUnitsPerSecond(void) {
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	return (uint32_t) ((double)tb.denom / (double)tb.numer * 1e9);
}

// Mirror of the real MTLResidencySet protocol, unannotated, so the bridge can talk to a real set
// on iOS 18+ without availability errors. All messages dispatch dynamically.
@protocol MBRealResidency <NSObject>
@optional
- (void)addAllocation:(id)allocation;
- (void)removeAllocation:(id)allocation;
- (void)requestResidency;
- (void)releaseResidency;
- (void)commit;
- (BOOL)containsAllocation:(id)allocation;
@end

/// Private declaration of the emulation descriptor class (its public face only exists in
/// caller builds via -DMTLResidencySetDescriptor=MBResidencySetDescriptor).
@interface MBResidencySetDescriptor : NSObject
@property (nonatomic) NSUInteger residentResourcesMaxSize;
@property (nonatomic) NSUInteger nonResidentResourcesMaxSize;
@property (nonatomic) NSUInteger initialPoolSize;
@end

@implementation MBResidencySetDescriptor
@synthesize residentResourcesMaxSize = _residentResourcesMaxSize;
@synthesize nonResidentResourcesMaxSize = _nonResidentResourcesMaxSize;
@synthesize initialPoolSize = _initialPoolSize;
@end

#pragma mark - Residency bridge

/// Builds a real MTLResidencySet from our descriptor on a device that has the API (iOS 18+);
/// returns nil below that.
static id MBRealResidencySet(id device, MBResidencySetDescriptor *descriptor, NSError **error) {
	if (@available(iOS 18.0, *)) {
		Class descClass = NSClassFromString(@"MTLResidencySetDescriptor");
		if (!descClass) return nil;
		id realDescriptor = [[descClass alloc] init];
		if ([realDescriptor respondsToSelector:@selector(setResidentResourcesMaxSize:)])
			[realDescriptor setValue:@(descriptor.residentResourcesMaxSize) forKey:@"residentResourcesMaxSize"];
		if ([realDescriptor respondsToSelector:@selector(setNonResidentResourcesMaxSize:)])
			[realDescriptor setValue:@(descriptor.nonResidentResourcesMaxSize) forKey:@"nonResidentResourcesMaxSize"];
		if ([realDescriptor respondsToSelector:@selector(setInitialPoolSize:)])
			[realDescriptor setValue:@(descriptor.initialPoolSize) forKey:@"initialPoolSize"];
		id (*msgSendResidency)(id, SEL, id, NSError **) =
			(id (*)(id, SEL, id, NSError **))objc_msgSend;
		return msgSendResidency(device, sel_getUid("newResidencySetWithDescriptor:error:"),
			realDescriptor, error);
	}
	return nil;
}

/// MBResidencySet conformance: delegates to the real set when one exists, otherwise keeps
/// bookkeeping only (iOS unified memory keeps every MTLResource resident).
@interface MBResidencySetImpl : NSObject <MBResidencySet>
- (instancetype)initWithReal:(id<MBRealResidency>)real;
- (instancetype)initEmulated;
+ (instancetype)setWithReal:(id<MBRealResidency>)real;
@property (nonatomic, readonly) id<MBRealResidency> real;
@end

@implementation MBResidencySetImpl {
	NSMutableSet *_tracked;
	id<MBRealResidency> _real;
}

- (instancetype)initWithReal:(id<MBRealResidency>)real {
	if (!(self = [super init])) return nil;
	_real = real;
	_tracked = [NSMutableSet set];
	return self;
}

- (instancetype)initEmulated {
	return [self initWithReal:nil];
}

+ (instancetype)setWithReal:(id<MBRealResidency>)real {
	return [[self alloc] initWithReal:real];
}

- (id<MBRealResidency>)real {
	return _real;
}

- (void)addAllocation:(id<MTLResource>)allocation {
	if (!allocation) return;
	[_tracked addObject:allocation];
	[_real addAllocation:allocation];
}

- (void)removeAllocation:(id<MTLResource>)allocation {
	if (!allocation) return;
	[_tracked removeObject:allocation];
	[_real removeAllocation:allocation];
}

- (void)requestResidency {
	[_real requestResidency];
}

- (void)releaseResidency {
	[_real releaseResidency];
}

- (void)commit {
	[_real commit];
}

- (BOOL)containsAllocation:(id<MTLResource>)allocation {
	if ([_real containsAllocation:allocation]) return YES;
	return [_tracked containsObject:allocation];
}

@end

#pragma mark - NSObject shim methods

// Call-time, nil-safe resolution of the real API: class_getInstanceMethod returns NULL when the
// runtime class (excluding our NSObject category, which carries only mb-named selectors) does not
// answer the selector, so there is no forwarding-stub path and no chance of re-entering the shim.

@implementation NSObject (MBMetalShims)

- (id)mbResidencySetWithDescriptor:(id)descriptor error:(NSError **)error {
	if (@available(iOS 18.0, *)) {
		id real = MBRealResidencySet(self, (MBResidencySetDescriptor *)descriptor, error);
		if (real) return [MBResidencySetImpl setWithReal:real];
		return nil;
	}
	(void)error;
	return [[MBResidencySetImpl alloc] initEmulated];
}

- (void)mbAddResidencySet:(id)set {
	id real = [set isKindOfClass:[MBResidencySetImpl class]]
		? ((MBResidencySetImpl *)set).real : nil;
	if (!real) return; // bookkeeping-only set (below iOS 18): the queue carries nothing real
	if (@available(iOS 18.0, *)) {
		Method m = class_getInstanceMethod(object_getClass(self), sel_getUid("addResidencySet:"));
		if (m) {
			void (*add)(id, SEL, id) = (void (*)(id, SEL, id))method_getImplementation(m);
			add(self, sel_getUid("addResidencySet:"), real);
			return;
		}
	}
	static _Atomic unsigned residLogs;
	if (++residLogs < 4 || residLogs % 2048 == 0)
		NSLog(@"[MBMetalShims] addResidencySet (unified-memory no-op below iOS 18, call #%u)", (unsigned)residLogs);
}

// MTLCompileOptions.mathMode is iOS 18+; below that the option is simply dropped (the runtime
// compiler has no fast-math switch there) and the getter reports what was requested.
static char MBMathModeKey;

- (void)setMbMathMode:(NSUInteger)mbMathMode {
	static _Atomic unsigned calls;
	unsigned n = ++calls;
	if (n < 4 || n % 64 == 0)
		NSLog(@"[MBMetalShims] mathMode=%lu (call #%u, stored)", (unsigned long)mbMathMode, n);
	if (@available(iOS 18.0, *)) {
		Method m = class_getInstanceMethod(object_getClass(self), sel_getUid("setMathMode:"));
		if (m) {
			void (*set)(id, SEL, NSUInteger) = (void (*)(id, SEL, NSUInteger))method_getImplementation(m);
			set(self, sel_getUid("setMathMode:"), mbMathMode);
			return;
		}
	}
	objc_setAssociatedObject(self, &MBMathModeKey, @(mbMathMode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSUInteger)mbMathMode {
	if (@available(iOS 18.0, *)) {
		Method m = class_getInstanceMethod(object_getClass(self), sel_getUid("mathMode"));
		if (m) {
			NSUInteger (*get)(id, SEL) = (NSUInteger (*)(id, SEL))method_getImplementation(m);
			return get(self, sel_getUid("mathMode"));
		}
	}
	return [objc_getAssociatedObject(self, &MBMathModeKey) unsignedIntegerValue];
}

@end

#pragma mark - CAMetalLayer shim

@implementation CAMetalLayer (MBMetalShims)

static char MBDisplaySyncKey;

- (BOOL)mbDisplaySyncEnabled {
	return [objc_getAssociatedObject(self, &MBDisplaySyncKey) boolValue];
}

- (void)setMbDisplaySyncEnabled:(BOOL)displaySyncEnabled {
	static _Atomic unsigned syncLogs;
	if (++syncLogs < 8 || syncLogs % 64 == 0)
		NSLog(@"[MBMetalShims] displaySyncEnabled=%d (call #%u)", displaySyncEnabled, (unsigned)syncLogs);
	objc_setAssociatedObject(self, &MBDisplaySyncKey, @(displaySyncEnabled),
		OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The macOS-named selectors exist for callers that message them directly; on iOS they ride on
// the same stored flag.
- (BOOL)displaySyncEnabled {
	return [self mbDisplaySyncEnabled];
}

- (void)setDisplaySyncEnabled:(BOOL)displaySyncEnabled {
	self.mbDisplaySyncEnabled = displaySyncEnabled;
}

@end

#pragma mark - CVDisplayLink over CADisplayLink

// Apple's CVDisplayLink runs its callback on a dedicated thread; CADisplayLink fires on the run
// loop that owns it and would stall when the owning run loop is busy. The shim spawns its own
// run loop thread, ticks the display link there and delivers the callback on a private serial
// queue, off the render and encode paths, so the caller's pacing math stays untouched.

struct __CVDisplayLink {
	CADisplayLink *link;
	CVDisplayLinkOutputCallback callback;
	void *userInfo;
	uint32_t videoTimeScale;
	BOOL started;
	dispatch_queue_t queue;
	pthread_t thread; // the dedicated run loop
	BOOL threadDone;
};

static void MBDisplayLinkThreadBody(struct __CVDisplayLink *dl) {
	@autoreleasepool {
		NSLog(@"[MBMetalShims] display link thread up (%u x per sec)", dl->videoTimeScale / 1000000);
		CFRunLoopRef loop = CFRunLoopGetCurrent();
		[dl->link addToRunLoop:(__bridge NSRunLoop *)loop forMode:NSDefaultRunLoopMode];
		while (!dl->threadDone) {
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
		}
	} // the source leaves with its run loop; CVDisplayLinkRelease invalidates the link
}

static void *MBDisplayLinkThreadEntry(void *arg) {
	MBDisplayLinkThreadBody((struct __CVDisplayLink *)arg);
	return NULL;
}

/// CADisplayLink target for a shimmed link: the display link retains its target, so the pump
/// lives as long as the link does.
@interface MBDisplayLinkPump : NSObject
@property (nonatomic, assign) struct __CVDisplayLink *dl;
- (void)tick:(CADisplayLink *)l;
@end

static void *MBDisplayLinkThreadEntry(void *arg); // defined below the body

@implementation MBDisplayLinkPump

- (void)tick:(CADisplayLink *)l {
	static _Atomic unsigned ticks;
	unsigned tick = ++ticks;
	if (tick < 4 || tick % 600 == 0)
		NSLog(@"[MBMetalShims] display link tick #%u (%.1fs since epoch)", tick, l.timestamp * 1e-3);
	struct __CVDisplayLink *me = self.dl;
	CVDisplayLinkOutputCallback cb = me->callback;
	if (!cb) return;
	double secondsPerUnit = MBSecondsPerUnit();
	double period = l.duration > 0 ? l.duration : 0;
	CVTimeStamp now;
	memset(&now, 0, sizeof(now));
	now.version = 0; // kCVTimeStampVersion0
	now.hostTime = mach_absolute_time();
	now.videoTimeScale = (int32_t)me->videoTimeScale;
	now.videoRefreshPeriod = (int64_t)(period * (double)me->videoTimeScale);
	now.videoTime = (int64_t)(l.timestamp / secondsPerUnit);
	now.rateScalar = 1.0;
	now.flags = kCVTimeStampVideoRefreshPeriodValid | kCVTimeStampVideoHostTimeValid;
	CVTimeStamp next = now;
	next.hostTime = (uint64_t)(l.targetTimestamp / secondsPerUnit);
	CVTimeStamp *stamps = (CVTimeStamp *)malloc(2 * sizeof(CVTimeStamp));
	if (!stamps) return;
	stamps[0] = now;
	stamps[1] = next;
	__block CVOptionFlags outFlags = 0;
	dispatch_async(me->queue, ^{
		cb(me, &stamps[0], &stamps[1], 0, &outFlags, me->userInfo);
		free(stamps);
	});
}

@end

extern "C" CVReturn CVDisplayLinkCreateWithCGDisplay(uint32_t display, CVDisplayLinkRef *displayLinkOut) {
	(void)display;
	if (!displayLinkOut) return -6671;
	*displayLinkOut = NULL;
	struct __CVDisplayLink *dl =
		(struct __CVDisplayLink *)calloc(1, sizeof(struct __CVDisplayLink));
	if (!dl) return -6672;
	dl->videoTimeScale = MBUnitsPerSecond();
	dl->queue = dispatch_queue_create("dev.metalbridge.cvdisplaylink", DISPATCH_QUEUE_SERIAL);
	NSLog(@"[MBMetalShims] display link created for display %u", display);
	MBDisplayLinkPump *pump = [MBDisplayLinkPump new];
	pump.dl = dl;
	dl->link = [CADisplayLink displayLinkWithTarget:pump selector:@selector(tick:)];
	// The display link retains its target, so the pump lives as long as the link; the link itself
	// lives because the delivery thread's run loop retains it and we retain it here.
	CFRetain((CFTypeRef)dl->link);
	*displayLinkOut = dl;
	return kCVReturnSuccess;
}

extern "C" CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef displayLink,
                                        CVDisplayLinkOutputCallback callback,
                                        void *userInfo) {
	if (!displayLink) return -6671;
	NSLog(@"[MBMetalShims] display link callback set (%p)", (void *)callback);
	displayLink->callback = callback;
	displayLink->userInfo = userInfo;
	return kCVReturnSuccess;
}

extern "C" CVReturn CVDisplayLinkStart(CVDisplayLinkRef displayLink) {
	if (!displayLink || !displayLink->link) return -6671;
	if (displayLink->started) return -6673;
	NSLog(@"[MBMetalShims] display link start");
	displayLink->threadDone = NO;
	if (pthread_create(&displayLink->thread, NULL,
		(void *(*)(void *))MBDisplayLinkThreadEntry,
		(void *)displayLink) == 0) {
		pthread_detach(displayLink->thread);
	} else {
		NSLog(@"[MBMetalShims] display link thread spawn failed, falling back to the main run loop");
		[displayLink->link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
	}
	displayLink->started = YES;
	return kCVReturnSuccess;
}

extern "C" CVReturn CVDisplayLinkStop(CVDisplayLinkRef displayLink) {
	if (!displayLink || !displayLink->link) return -6671;
	if (!displayLink->started) return -6674;
	NSLog(@"[MBMetalShims] display link stop");
	displayLink->threadDone = YES;
	displayLink->started = NO;
	return kCVReturnSuccess;
}

extern "C" void CVDisplayLinkRelease(CVDisplayLinkRef displayLink) {
	if (!displayLink) return;
	NSLog(@"[MBMetalShims] display link release");
	[displayLink->link invalidate];
	CFRelease((CFTypeRef)displayLink->link);
	CFRelease((CFTypeRef)displayLink->queue);
	free(displayLink);
}

extern "C" uint32_t CGMainDisplayID(void) {
	return 1; // the one screen that matters here
}

#endif // !TARGET_OS_OSX
