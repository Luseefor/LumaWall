//
//  WallpaperExtension-Bridging-Header.h
//  WallpaperVideoExtension
//
//  ObjC protocol definitions matching WallpaperExtensionKit.
//  XPC type classes are loaded at runtime via dlopen.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <bsm/libbsm.h>

// MARK: - Display layer setup off the main thread
//
// The macOS 26 SDK marks these AVSampleBufferDisplayLayer properties as
// main-actor isolated for Swift. The extension has no UI: it builds and feeds
// its layers on its own serial lifecycle queue inside a remote CAContext, and
// moving that work to the main thread would add a hop to every renderer
// create. These helpers keep the existing threading explicit in one place.

static inline AVSampleBufferVideoRenderer * _Nonnull LWSampleBufferRenderer(AVSampleBufferDisplayLayer * _Nonnull layer) {
    return layer.sampleBufferRenderer;
}

static inline void LWSetVideoGravity(AVSampleBufferDisplayLayer * _Nonnull layer, AVLayerVideoGravity _Nonnull gravity) {
    layer.videoGravity = gravity;
}

static inline void LWSetControlTimebase(AVSampleBufferDisplayLayer * _Nonnull layer, CMTimebaseRef _Nullable timebase) {
    layer.controlTimebase = timebase;
}

// MARK: - Private NSXPCConnection caller identity
//
// NSXPCConnection exposes the connecting peer's audit token as private API.
// Declaring it here lets Swift read the token to validate the caller's code
// signature before accepting a connection. Guarded with -respondsToSelector:
// at the call site so a future OS that drops the SPI degrades gracefully.

@interface NSXPCConnection (LumaWallCallerIdentity)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

// MARK: - Private CAContext API (for remote rendering)

@interface CAContext : NSObject
@property (readonly) unsigned int contextId;
@property (retain) CALayer *layer;
+ (id)remoteContext;
+ (id)remoteContextWithOptions:(id)options;
+ (id)contextWithCGSConnection:(unsigned int)cgsconnection options:(id)options;
+ (void)setAllowsCGSConnections:(_Bool)cgsconnections;
@end

// MARK: - Private CGS API

extern unsigned int CGSMainConnectionID(void);

// MARK: - Extension → Host protocol (what we can call on WallpaperAgent)

@protocol WallpaperExtensionProxyXPCProtocol <NSObject>
- (void)pingWithId:(id _Nullable)anId;
- (void)updateSettingsViewModels:(id _Nullable)models reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)requestReadOnlyAccessTo:(id _Nullable)url reply:(void (^ _Nonnull)(id _Nullable))reply;
- (void)invalidateSnapshotsWithReply:(void (^ _Nonnull)(NSError * _Nullable))reply;
@end

// MARK: - Host → Extension protocol (what WallpaperAgent calls on us)

@protocol WallpaperExtensionXPCProtocol <NSObject>

// Lifecycle
- (void)acquireWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)updateWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invalidateWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)snapshotWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Settings
- (void)provideSettingsViewModelsWithContentTypes:(id _Nullable)types reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;

// Choices
- (void)addChoiceRequestWithChoiceRequest:(id _Nullable)request onBehalfOfProcess:(id _Nullable)process reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id _Nullable)request reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)selectedChoicesDidChangeFor:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)invokeContextMenuActionWithMenuItemID:(id _Nullable)menuItemID groupItemID:(id _Nullable)groupItemID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Downloads
- (void)isChoiceDownloadedWith:(id _Nullable)choiceID reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;
- (id _Nullable)downloadWithChoiceID:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)pauseDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)cancelDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)resumeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)removeDownloadFor:(id _Nullable)choiceID reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Migration
- (void)migrateSelectedChoiceFor:(id _Nullable)anId reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)migrateFrom:(id _Nullable)from to:(id _Nullable)to reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

// Shuffle
- (void)skipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(NSError * _Nullable))reply;
- (void)canSkipShuffledContentWithId:(id _Nullable)anId reply:(void (^ _Nonnull)(BOOL, NSError * _Nullable))reply;

// Debug & notifications
- (void)handleDebugRequestFor:(id _Nullable)request reply:(void (^ _Nonnull)(id _Nullable, NSError * _Nullable))reply;
- (void)handleNotificationWithNamed:(id _Nullable)name reply:(void (^ _Nonnull)(NSError * _Nullable))reply;

@end
