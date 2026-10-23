#import "Mail.h"

NS_ASSUME_NONNULL_BEGIN
/// Resolve only native-filtered message references, never message bodies.
/// Catches Objective-C predicate exceptions which Swift cannot catch. Errors
/// are sanitized and must never be treated as an empty successful search.
FOUNDATION_EXPORT NSArray<MailMessage *> * _Nullable APSMailSearchMessages(
    MailApplication *application, SBElementArray *messages,
    NSPredicate *predicate, NSError **error);
NS_ASSUME_NONNULL_END
