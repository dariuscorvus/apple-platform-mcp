#import "Notes.h"
#import <ScriptingBridge/ScriptingBridge.h>

@interface APSNotesErrorDelegate : NSObject <SBApplicationDelegate>
@property(nonatomic, strong) NSError *error;
@end
@implementation APSNotesErrorDelegate
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
  self.error = error;
  return nil;
}
@end

static id APSNotesValue(SBObject *object, OSType code) {
  return [[object propertyWithCode:code] get];
}
static NSString *APSNotesID(SBObject *object) { return APSNotesValue(object, 'ID  '); }
static NSArray *APSNotesElements(SBObject *object, OSType code) {
  return [[object elementArrayWithCode:code] get] ?: @[];
}
static SBObject *APSNotesFind(NSArray *objects, NSString *identifier) {
  SBObject *match = nil;
  for (SBObject *object in objects) {
    if ([APSNotesID(object) isEqual:identifier]) {
      if (match) @throw [NSException exceptionWithName:@"ambiguousReference" reason:nil userInfo:nil];
      match = object;
    }
  }
  if (!match) @throw [NSException exceptionWithName:@"notesNotFound" reason:nil userInfo:nil];
  return match;
}
static void APSNotesFolders(SBObject *parent, NSMutableArray *folders, NSUInteger depth) {
  if (depth > 32 || folders.count > 1000)
    @throw [NSException exceptionWithName:@"notesTraversalLimit" reason:nil userInfo:nil];
  for (SBObject *folder in APSNotesElements(parent, 'cfol')) {
    [folders addObject:folder];
    APSNotesFolders(folder, folders, depth + 1);
  }
}
static NSDictionary *APSNotesMetadata(SBObject *note) {
  return @{@"id": APSNotesID(note) ?: @"", @"name": APSNotesValue(note, 'pnam') ?: @"",
           @"locked": APSNotesValue(note, 'pwpr') ?: @YES};
}
NSDictionary *APSNotesExecute(NSDictionary *request, NSError **error) {
  APSNotesErrorDelegate *delegate = [APSNotesErrorDelegate new];
  SBApplication *app = [SBApplication applicationWithBundleIdentifier:@"com.apple.Notes"];
  app.delegate = delegate;
  app.timeout = 30 * 60; // Apple Event ticks (30 seconds), not wall-clock operation budget.
  NSDictionary *result = nil;
  @try {
    if (!app) @throw [NSException exceptionWithName:@"notesUnavailable" reason:nil userInfo:nil];
    NSString *operation = request[@"operation"];
    NSArray *accounts = APSNotesElements(app, 'acct');
    if ([operation isEqual:@"accounts"]) {
      NSMutableArray *items = [NSMutableArray new];
      for (SBObject *account in accounts)
        [items addObject:@{@"id": APSNotesID(account) ?: @"", @"name": APSNotesValue(account, 'pnam') ?: @""}];
      result = @{@"items": items};
    } else {
      SBObject *account = APSNotesFind(accounts, request[@"account"]);
      NSMutableArray *folders = [NSMutableArray new];
      APSNotesFolders(account, folders, 0);
      if ([operation isEqual:@"folders"]) {
        NSMutableArray *items = [NSMutableArray new];
        for (SBObject *folder in folders)
          [items addObject:@{@"id": APSNotesID(folder) ?: @"", @"name": APSNotesValue(folder, 'pnam') ?: @""}];
        result = @{@"items": items};
      } else {
        SBObject *folder = APSNotesFind(folders, request[@"folder"]);
        if ([operation isEqual:@"create"]) {
          BOOL shared = [APSNotesValue(folder, 'shrd') boolValue];
          if (delegate.error) @throw [NSException exceptionWithName:@"notesAutomationFailed" reason:nil userInfo:nil];
          if (shared)
            @throw [NSException exceptionWithName:@"notesSharedFolder" reason:nil userInfo:nil];
          Class noteClass = [app classForScriptingClass:@"note"];
          if (!noteClass) @throw [NSException exceptionWithName:@"notesUnavailable" reason:nil userInfo:nil];
          SBObject *note = [[noteClass alloc] initWithProperties:@{@"body": request[@"html"]}];
          [[folder elementArrayWithCode:'note'] addObject:note];
          result = APSNotesMetadata(note);
        } else if ([operation isEqual:@"get"]) {
          SBObject *note = APSNotesFind(APSNotesElements(folder, 'note'), request[@"note"]);
          if ([APSNotesValue(note, 'pwpr') boolValue])
            @throw [NSException exceptionWithName:@"notesLocked" reason:nil userInfo:nil];
          NSMutableDictionary *item = [APSNotesMetadata(note) mutableCopy];
          item[@"text"] = APSNotesValue(note, 'text') ?: @"";
          result = item;
        } else if ([operation isEqual:@"search"]) {
          NSMutableArray *items = [NSMutableArray new];
          NSUInteger scanned = 0;
          BOOL truncated = NO;
          SBElementArray *notes = [folder elementArrayWithCode:'note'];
          NSUInteger count = notes.count;
          NSUInteger limit = [request[@"limit"] unsignedIntegerValue];
          for (NSUInteger index = 0; index < count; index++) {
            if (scanned >= 1000 || items.count >= limit) { truncated = YES; break; }
            SBObject *note = [notes objectAtIndex:index];
            scanned++;
            NSString *name = APSNotesValue(note, 'pnam') ?: @"";
            if ([request[@"query"] length] == 0 || [name rangeOfString:request[@"query"] options:NSCaseInsensitiveSearch].location != NSNotFound)
              [items addObject:APSNotesMetadata(note)];
          }
          result = @{@"items": items, @"truncated": @(truncated)};
        } else @throw [NSException exceptionWithName:@"invalidInput" reason:nil userInfo:nil];
      }
    }
  } @catch (NSException *exception) {
    if (error) *error = [NSError errorWithDomain:@"ApplePlatformNotes" code:1
      userInfo:@{@"notesCode": delegate.error ? (delegate.error.code == -1743 ? @"notesPermissionDenied" : @"notesAutomationFailed") : exception.name}];
    return nil;
  }
  if (delegate.error) {
    if (error) *error = [NSError errorWithDomain:@"ApplePlatformNotes" code:delegate.error.code
      userInfo:@{@"notesCode": delegate.error.code == -1743 ? @"notesPermissionDenied" : @"notesAutomationFailed"}];
    return nil;
  }
  return result;
}
