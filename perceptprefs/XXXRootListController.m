#import <Foundation/Foundation.h>
#import "XXXRootListController.h"

@implementation XXXRootListController

- (NSArray *)specifiers {
	NSArray *specifiers = [super specifiers];

	if (!specifiers) {
		specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		[self setSpecifiers:specifiers];
	}

	return specifiers;
}

@end
