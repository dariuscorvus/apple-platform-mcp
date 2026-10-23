#import "MailSearch.h"

@interface APSMailSearchErrorDelegate : NSObject <SBApplicationDelegate>
@property(nonatomic, strong) NSError *error;
@end
@implementation APSMailSearchErrorDelegate
- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
  self.error = error;
  return nil;
}
@end

NSArray<MailMessage *> *APSMailSearchMessages(
    MailApplication *application, SBElementArray *messages,
    NSPredicate *predicate, NSError **error) {
  APSMailSearchErrorDelegate *delegate = [APSMailSearchErrorDelegate new];
  id<SBApplicationDelegate> previousDelegate = application.delegate;
  NSInteger previousTimeout = application.timeout;
  application.delegate = delegate;
  application.timeout = 20 * 60; // Apple Event ticks; bounds one native query.
  @try {
    // Keep filtering in Objective-C: Swift's NSArray bridge can eagerly
    // enumerate the remote collection. `get` resolves the filtered references
    // once, avoiding re-evaluation of the whose clause for each property read.
    id filtered = [messages filteredArrayUsingPredicate:predicate];
    if (![filtered isKindOfClass:[SBElementArray class]]) {
      @throw [NSException exceptionWithName:@"nativeFilterRequired" reason:nil userInfo:nil];
    }
    NSArray *result = [filtered get];
    if (delegate.error || ![result isKindOfClass:[NSArray class]]) {
      if (error) *error = [NSError errorWithDomain:@"APSMailSearch" code:delegate.error.code ?: 2
          userInfo:@{NSLocalizedDescriptionKey: @"Mail.app could not evaluate the native search."}];
      return nil;
    }
    for (id message in result) {
      if (![message isKindOfClass:[MailMessage class]]) {
        if (error) *error = [NSError errorWithDomain:@"APSMailSearch" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Mail.app returned invalid search references."}];
        return nil;
      }
    }
    return result;
  } @catch (NSException *exception) {
    // Exception reasons may contain predicate values (sender/subject).
    if (error) *error = [NSError errorWithDomain:@"APSMailSearch" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Mail.app native search predicate is unsupported."}];
    return nil;
  } @finally {
    application.delegate = previousDelegate;
    application.timeout = previousTimeout;
  }
}
