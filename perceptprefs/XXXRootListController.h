#import <UIKit/UIKit.h>

// Preferences.framework is private and ships no headers in the SDK, so declare the
// slice of PSListController this controller needs. Ivars are deliberately not declared:
// the superclass's _specifiers is reached through its accessors instead, which keeps
// this independent of the real ivar layout.
@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)specifiers;
- (void)setSpecifiers:(NSArray *)specifiers;
@end

@interface XXXRootListController : PSListController

@end
