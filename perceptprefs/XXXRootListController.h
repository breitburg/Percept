#import <UIKit/UIKit.h>

// Preferences.framework is private and ships no headers in the SDK, so declare the slice
// of PSListController this controller needs. _specifiers is declared just as theos' headers
// do: Preferences exports its ivar offset symbol, which is bound at load time, so assigning
// it directly keeps the superclass's own bookkeeping in sync.
@interface PSListController : UIViewController {
	NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface XXXRootListController : PSListController

@end
