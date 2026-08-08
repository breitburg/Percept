#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Percept - routes Siri queries to an OpenAI-compatible endpoint on iOS 9.
//
// How it works, and why it works this way:
//
//   * Apple still performs speech recognition. On iOS 9 there is no on-device recogniser, so
//     the transcript itself comes back from Apple's servers - it cannot be avoided if voice
//     input is wanted. The query therefore still reaches Apple; only the answer is replaced.
//
//   * -[AFConnection _tellSpeechDelegateSpeechRecognized:] carries that transcript, reachable
//     as af_bestTextInterpretation.
//
//   * Apple's own answer arrives at -[AFConnectionClientServiceDelegate
//     requestDidReceiveCommand:reply:] as an SAUIAddViews, and is dropped there. Cancelling
//     the request instead does nothing: the answer lands in the same second regardless.
//
//   * Our reply is injected through -[AFUISiriSession performAceCommand:]. It is then echoed
//     back through the same inbound path as Apple's, so the two must be told apart by content
//     - matching the text just injected. Dropping by class alone also drops our own reply.

static NSString * const kLogPath = @"/var/tmp/percept.log";
static NSString * const kPrefsPath = @"/var/mobile/Library/Preferences/com.breitburg.Percept.plist";
static NSString * const kDefaultBaseURL = @"https://api.openai.com/v1/";
static NSString * const kDefaultModel = @"gpt-5.6-luna";
static NSString * const kDefaultSystemPrompt = @"You are Siri. Respond with 1-2 concise paragraphs.";

static NSString *gLastInjectedReply = nil;

// Every exchange so far, as {role, content} pairs, deliberately untrimmed. It lives only in
// SpringBoard's memory, so a respring clears it; nothing is written to disk. Guarded because
// it is read on a background queue while Siri may already be starting the next request.
static NSMutableArray *gConversation = nil;

static void PerceptLog(NSString *format, ...) {
    @autoreleasepool {
        va_list arguments;
        va_start(arguments, format);
        NSString *message = [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease];
        va_end(arguments);

        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!handle) {
            [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    }
}

static id SafeCall(id target, SEL selector) {
    if (target && [target respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    }
    return nil;
}

static void SetBool(id target, SEL selector, BOOL value) {
    if (target && [target respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
    }
}

#pragma mark - Network

static NSString *PerceptFetchReply(NSString *prompt) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    NSString *apiKey = [prefs objectForKey:@"apiKey"];
    if ([apiKey length] == 0) {
        return @"Set your API key in the Percept settings panel first.";
    }

    NSString *baseURL = [prefs objectForKey:@"baseURL"];
    if ([baseURL length] == 0) baseURL = kDefaultBaseURL;
    if (![baseURL hasSuffix:@"/"]) baseURL = [baseURL stringByAppendingString:@"/"];

    NSString *model = [prefs objectForKey:@"model"];
    if ([model length] == 0) model = kDefaultModel;

    NSString *systemPrompt = [prefs objectForKey:@"systemPrompt"];
    if (systemPrompt == nil) systemPrompt = kDefaultSystemPrompt;

    NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingString:@"chat/completions"]];
    if (!url) return @"The base URL in Percept settings isn't a valid address.";

    NSDictionary *userMessage = [NSDictionary dictionaryWithObjectsAndKeys:
                                 @"user", @"role", prompt, @"content", nil];

    NSMutableArray *messages = [NSMutableArray array];
    if ([systemPrompt length] > 0) {
        [messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                             @"system", @"role", systemPrompt, @"content", nil]];
    }
    @synchronized (gConversation) {
        [messages addObjectsFromArray:gConversation];
    }
    [messages addObject:userMessage];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    [request setTimeoutInterval:20.0];

    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          model, @"model",
                          messages, @"messages",
                          [NSNumber numberWithInt:1024], @"max_tokens", nil];
    [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:NULL]];

    // NSURLSession, not +sendSynchronousRequest:: the latter has no delegate to answer the TLS
    // server-trust challenge on iOS 9 and fails with -1012, which is what earlier versions of
    // this project worked around with a PHP proxy.
    __block NSData *data = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *taskData, NSURLResponse *response, NSError *error) {
            data = [taskData retain];
            requestError = [error retain];
            dispatch_semaphore_signal(semaphore);
        }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)));
    dispatch_release(semaphore);

    [data autorelease];
    [requestError autorelease];

    if (requestError || !data) {
        PerceptLog(@"network error: %@", requestError.localizedDescription);
        return @"I couldn't reach the server.";
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return @"I couldn't read the response.";

    NSString *content = [[[[json objectForKey:@"choices"] firstObject]
                          objectForKey:@"message"] objectForKey:@"content"];
    if ([content length] > 0) {
        NSString *reply = [content stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Recorded only on success, so a network or API failure never enters the history as
        // though the assistant had said it.
        @synchronized (gConversation) {
            [gConversation addObject:userMessage];
            [gConversation addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                      @"assistant", @"role", reply, @"content", nil]];
        }

        return reply;
    }

    NSString *apiMessage = [[json objectForKey:@"error"] objectForKey:@"message"];
    return [apiMessage length] > 0 ? apiMessage : @"I got an empty response.";
}

#pragma mark - Formatting

static NSString *PerceptApplyInlineMarkup(NSString *line) {
    // Bold first: **x** would otherwise be eaten by the italic pattern.
    NSArray *patterns = [NSArray arrayWithObjects:
                         @"\\*\\*(.+?)\\*\\*", @"<b>$1</b>",
                         @"`(.+?)`", @"<code>$1</code>",
                         @"\\*(.+?)\\*", @"<i>$1</i>", nil];

    NSMutableString *result = [[line mutableCopy] autorelease];
    for (NSUInteger index = 0; index + 1 < [patterns count]; index += 2) {
        NSRegularExpression *expression =
            [NSRegularExpression regularExpressionWithPattern:[patterns objectAtIndex:index]
                                                      options:0 error:NULL];
        [expression replaceMatchesInString:result options:0
                                     range:NSMakeRange(0, [result length])
                              withTemplate:[patterns objectAtIndex:index + 1]];
    }
    return result;
}

// Models answer in markdown, which would otherwise be read out as literal asterisks.
static NSString *PerceptHTMLFromMarkdown(NSString *markdown) {
    NSMutableString *escaped = [[markdown mutableCopy] autorelease];
    NSArray *entities = [NSArray arrayWithObjects:@"&", @"&amp;", @"<", @"&lt;", @">", @"&gt;", nil];
    for (NSUInteger index = 0; index + 1 < [entities count]; index += 2) {
        [escaped replaceOccurrencesOfString:[entities objectAtIndex:index]
                                 withString:[entities objectAtIndex:index + 1]
                                    options:0 range:NSMakeRange(0, [escaped length])];
    }

    NSMutableString *body = [NSMutableString string];
    BOOL inList = NO;

    for (NSString *line in [escaped componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] == 0) {
            continue;
        }

        BOOL isBullet = [trimmed hasPrefix:@"- "] || [trimmed hasPrefix:@"* "];
        if (isBullet && !inList) {
            [body appendString:@"<ul>"];
            inList = YES;
        } else if (!isBullet && inList) {
            [body appendString:@"</ul>"];
            inList = NO;
        }

        if (isBullet) {
            [body appendFormat:@"<li>%@</li>",
                PerceptApplyInlineMarkup([trimmed substringFromIndex:2])];
        } else {
            [body appendFormat:@"<p>%@</p>", PerceptApplyInlineMarkup(trimmed)];
        }
    }
    if (inList) {
        [body appendString:@"</ul>"];
    }

    // White text: the iOS 9 Siri sheet is a dark blur, and a UIWebView would otherwise
    // default to black and render invisible.
    return [NSString stringWithFormat:
            @"<div style=\"font-family:-apple-system,Helvetica;font-size:15px;"
            @"color:#fff;margin:0\">%@</div>", body];
}

#pragma mark - Injection

// SAUIHtmlView is dictionary-backed and ships no headers, so the setter carrying its markup
// cannot be known ahead of time. Try the plausible names and report which one bound; returns
// nil if none did, so the caller can fall back to a plain utterance rather than render nothing.
static id PerceptBuildHTMLView(NSString *reply) {
    Class htmlClass = objc_getClass("SAUIHtmlView");
    if (!htmlClass) return nil;

    // Guarded: an unrecognised class method here would raise inside SpringBoard and take the
    // whole UI down. +aceView is the inherited SAAceView factory, tried if +htmlView is absent.
    SEL factory = 0;
    if ([htmlClass respondsToSelector:@selector(htmlView)]) {
        factory = @selector(htmlView);
    } else if ([htmlClass respondsToSelector:@selector(aceView)]) {
        factory = @selector(aceView);
    } else {
        PerceptLog(@"SAUIHtmlView has no known factory - falling back to utterance");
        return nil;
    }

    id view = ((id (*)(id, SEL))objc_msgSend)(htmlClass, factory);
    if (!view) return nil;

    NSString *html = PerceptHTMLFromMarkdown(reply);
    NSArray *setters = [NSArray arrayWithObjects:@"setHtml:", @"setHtmlString:",
                        @"setHTML:", @"setContent:", @"setText:", nil];

    for (NSString *name in setters) {
        SEL setter = NSSelectorFromString(name);
        if ([view respondsToSelector:setter]) {
            [view performSelector:setter withObject:html];
            PerceptLog(@"html view via %@", name);
            return view;
        }
    }

    PerceptLog(@"SAUIHtmlView exposes no known setter - falling back to utterance");
    return nil;
}

static void PerceptSpeak(id session, NSString *reply) {
    Class utteranceClass = objc_getClass("SAUIAssistantUtteranceView");
    Class addViewsClass = objc_getClass("SAUIAddViews");
    Class completedClass = objc_getClass("SARequestCompleted");
    if (!utteranceClass || !addViewsClass || !completedClass) return;

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    id renderHTML = [prefs objectForKey:@"renderHTML"];
    id view = (renderHTML == nil || [renderHTML boolValue]) ? PerceptBuildHTMLView(reply) : nil;

    if (!view) {
        view = ((id (*)(id, SEL))objc_msgSend)(utteranceClass, @selector(assistantUtteranceView));
        [view performSelector:@selector(setText:) withObject:reply];
        [view performSelector:@selector(setDialogIdentifier:) withObject:@"Misc#ident"];
    }

    id utterance = view;
    // speakableText, inherited from SAAceView by every view type, is what drives TTS; setting
    // only `text` renders silently, and an HTML view has no `text` at all.
    [utterance performSelector:@selector(setSpeakableText:) withObject:reply];
    SetBool(utterance, @selector(setListenAfterSpeaking:), NO);

    id addViews = ((id (*)(id, SEL))objc_msgSend)(addViewsClass, @selector(addViews));
    [addViews performSelector:@selector(setViews:) withObject:[NSArray arrayWithObject:utterance]];
    [addViews performSelector:@selector(setDialogPhase:) withObject:@"Completion"];
    SetBool(addViews, @selector(setTemporary:), NO);
    SetBool(addViews, @selector(setScrollToTop:), NO);

    id completed = ((id (*)(id, SEL))objc_msgSend)(completedClass, @selector(requestCompleted));

    // Recorded before sending: the command comes straight back through the inbound hook, which
    // uses this to recognise it as ours rather than Apple's.
    [gLastInjectedReply autorelease];
    gLastInjectedReply = [reply copy];

    [session performSelector:@selector(performAceCommand:) withObject:addViews];
    [session performSelector:@selector(performAceCommand:) withObject:completed];
}

#pragma mark - Hooks

static void (*original_requestDidReceiveCommand)(id, SEL, id, id);
static void replaced_requestDidReceiveCommand(id self, SEL _cmd, id command, id reply) {
    BOOL suppress = NO;

    @autoreleasepool {
        id views = SafeCall(command, @selector(views));
        if ([NSStringFromClass([command class]) isEqualToString:@"SAUIAddViews"] &&
            [views isKindOfClass:[NSArray class]]) {

            // speakableText is checked too, and first: an HTML view has no `text`, so matching
            // on that alone would mistake our own reply for Apple's and suppress it.
            BOOL isOurs = NO;
            for (id view in (NSArray *)views) {
                NSString *speakable = (NSString *)SafeCall(view, @selector(speakableText));
                NSString *text = (NSString *)SafeCall(view, @selector(text));
                if (gLastInjectedReply &&
                    ([speakable isEqualToString:gLastInjectedReply] ||
                     [text isEqualToString:gLastInjectedReply])) {
                    isOurs = YES;
                    break;
                }
            }
            suppress = !isOurs;
        }
    }

    // Dropped rather than emptied: these ace objects are dictionary-backed, so mutating `views`
    // does not affect rendering. The method is `oneway void`, so no caller is left blocked.
    if (suppress) {
        return;
    }

    original_requestDidReceiveCommand(self, _cmd, command, reply);
}

static void (*original_tellSpeechRecognized)(id, SEL, id);
static void replaced_tellSpeechRecognized(id self, SEL _cmd, id recognized) {
    NSString *transcript = (NSString *)SafeCall(recognized, @selector(af_bestTextInterpretation));
    id delegate = SafeCall(self, @selector(delegate));

    // Renders the user's own words as the request bubble.
    original_tellSpeechRecognized(self, _cmd, recognized);

    Class sessionClass = objc_getClass("AFUISiriSession");
    id session = [delegate isKindOfClass:sessionClass] ? delegate : nil;
    if (!session || [transcript length] == 0) {
        return;
    }

    [session retain];
    [transcript retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *reply = PerceptFetchReply(transcript);
        dispatch_async(dispatch_get_main_queue(), ^{
            PerceptSpeak(session, reply);
            [session release];
            [transcript release];
        });
    });
}

static BOOL SwizzleMethod(Class cls, SEL selector, IMP replacement, void *originalStore) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        PerceptLog(@"missing %@ - Percept inactive", NSStringFromSelector(selector));
        return NO;
    }
    *(IMP *)originalStore = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return YES;
}

__attribute__((constructor))
static void PerceptInit(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
            return;
        }

        gConversation = [[NSMutableArray alloc] init];

        // AssistantUI and friends load lazily; force them so the classes resolve now.
        dlopen("/System/Library/PrivateFrameworks/AssistantUI.framework/AssistantUI", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/SAObjects.framework/SAObjects", RTLD_LAZY);

        Class connectionClass = objc_getClass("AFConnection");
        Class inboundClass = objc_getClass("AFConnectionClientServiceDelegate");

        BOOL ok = YES;
        if (inboundClass) {
            ok &= SwizzleMethod(inboundClass, @selector(requestDidReceiveCommand:reply:),
                                (IMP)replaced_requestDidReceiveCommand, &original_requestDidReceiveCommand);
        }
        if (connectionClass) {
            ok &= SwizzleMethod(connectionClass, @selector(_tellSpeechDelegateSpeechRecognized:),
                                (IMP)replaced_tellSpeechRecognized, &original_tellSpeechRecognized);
        }

        PerceptLog(@"Percept active (pid %d) hooks=%@", getpid(), ok ? @"ok" : @"PARTIAL");
    }
}
