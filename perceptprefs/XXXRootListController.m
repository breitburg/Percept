#import <Foundation/Foundation.h>
#import "XXXRootListController.h"

@implementation XXXRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		// Retained explicitly: this bundle is built without ARC, and the returned array
		// is autoreleased, so storing it unretained would leave the ivar dangling.
		_specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] retain];
	}

	return _specifiers;
}

@end
