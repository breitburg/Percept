#import "AICommands.h"

#define PREFS_PATH @"/var/mobile/Library/Preferences/com.breitburg.Percept.plist"
#define DEFAULT_BASE_URL @"https://api.openai.com/v1/"
#define DEFAULT_MODEL @"gpt-5.6-luna"
#define MAX_TOKENS 1024

@implementation AIAssistantExtension

-(id)initWithSystem:(id<SESystem>)system {
    if ((self = [super init])) {
        [system registerCommand:[AICommands class]];
    }
    return self;
}

-(NSString*)author { return @"breitburg"; }
-(NSString*)name { return @"Percept"; }
-(NSString*)description { return @"Makes Siri just a little bit smarter."; }

@end

@implementation AICommands

-(id)init {
    if ((self = [super init])) {
        _queue = [[NSOperationQueue alloc] init];
        [_queue setMaxConcurrentOperationCount:1];
    }
    return self;
}

-(void)dealloc {
    [_queue release];
    [super dealloc];
}

-(void)processRequest:(NSString*)text {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSString *apiKey = [prefs objectForKey:@"apiKey"];

    if ([apiKey length] == 0) {
        [_ctx sendAddViewsUtteranceView:@"Please set your API key in the Percept settings panel first." speakableText:@""];
        [_ctx sendRequestCompleted];
        _ctx = nil;
        [pool release];
        return;
    }

    NSString *baseURL = [prefs objectForKey:@"baseURL"];
    if ([baseURL length] == 0) {
        baseURL = DEFAULT_BASE_URL;
    }
    if (![baseURL hasSuffix:@"/"]) {
        baseURL = [baseURL stringByAppendingString:@"/"];
    }

    NSString *model = [prefs objectForKey:@"model"];
    if ([model length] == 0) {
        model = DEFAULT_MODEL;
    }

    NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingString:@"chat/completions"]];
    if (!url) {
        [_ctx sendAddViewsUtteranceView:@"The base URL in Percept settings isn't a valid address." speakableText:@""];
        [_ctx sendRequestCompleted];
        _ctx = nil;
        [pool release];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    [request setTimeoutInterval:20.0];

    NSDictionary *message = [NSDictionary dictionaryWithObjectsAndKeys:
                             @"user", @"role",
                             text, @"content",
                             nil];

    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          model, @"model",
                          [NSArray arrayWithObject:message], @"messages",
                          [NSNumber numberWithInt:MAX_TOKENS], @"max_tokens",
                          nil];

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];

    if (error) {
        [_ctx sendAddViewsUtteranceView:@"Failed to create request." speakableText:@""];
        [_ctx sendRequestCompleted];
        _ctx = nil;
        [pool release];
        return;
    }

    [request setHTTPBody:jsonData];

    // NSURLSession rather than +sendSynchronousRequest:: the latter has no delegate to answer
    // the TLS server-trust challenge and fails with -1012, which is what the PHP proxy worked around.
    __block NSData *data = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *taskData, NSURLResponse *taskResponse, NSError *taskError) {
            data = [taskData retain];
            requestError = [taskError retain];
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)));
    dispatch_release(semaphore);

    [data autorelease];
    [requestError autorelease];

    if (!_ctx) {
        [pool release];
        return;
    }

    if (requestError || !data) {
        [_ctx sendAddViewsUtteranceView:@"Network error." speakableText:@""];
        [_ctx sendRequestCompleted];
        _ctx = nil;
        [pool release];
        return;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    if (error || ![json isKindOfClass:[NSDictionary class]]) {
        [_ctx sendAddViewsUtteranceView:@"Failed to parse response." speakableText:@""];
        [_ctx sendRequestCompleted];
        _ctx = nil;
        [pool release];
        return;
    }

    NSArray *choices = [json objectForKey:@"choices"];
    if ([choices count] > 0) {
        NSDictionary *choice = [choices objectAtIndex:0];
        NSDictionary *messageDict = [choice objectForKey:@"message"];
        NSString *content = [messageDict objectForKey:@"content"];

        if ([content length] > 0) {
            content = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [_ctx sendAddViewsUtteranceView:content];
            [_ctx sendRequestCompleted];
            _ctx = nil;
            [pool release];
            return;
        }
    }

    // Surfacing the API's own message makes a wrong base URL, model or key diagnosable on-device.
    NSString *apiMessage = [[json objectForKey:@"error"] objectForKey:@"message"];
    if ([apiMessage length] > 0) {
        [_ctx sendAddViewsUtteranceView:apiMessage speakableText:@""];
    } else {
        [_ctx sendAddViewsUtteranceView:@"Invalid network response, please try again later." speakableText:@""];
    }

    [_ctx sendRequestCompleted];
    _ctx = nil;
    [pool release];
}

-(BOOL)handleSpeech:(NSString*)text tokens:(NSArray*)tokens tokenSet:(NSSet*)tokenset context:(id<SEContext>)ctx {

    if (_ctx) return NO;

    _ctx = ctx;

    NSString *reflection = @"...";
    [ctx sendAddViewsUtteranceView:reflection speakableText:@"" dialogPhase:@"Reflection" scrollToTop:NO temporary:NO];

    [self performSelectorInBackground:@selector(processRequest:) withObject:text];

    return YES;
}
@end
