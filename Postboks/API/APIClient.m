//
//  Created by Ole Gammelgaard Poulsen on 15/08/14.
//  Copyright (c) 2014 SHAPE A/S. All rights reserved.
//

#import "APIClient.h"
#import "EboksAccount.h"
#import "NSString+EboksAdditions.h"
#import <AFOnoResponseSerializer/AFOnoResponseSerializer.h>
#import <ReactiveCocoa/ReactiveCocoa/RACSignal.h>
#import "ONOXMLDocument.h"
#import "EboksSession.h"
#import "RegExCategories.h"
#import "NSArray+F.h"
#import "MessageInfo.h"
#import "EboksFolderInfo.h"
#import <AFNetworking/AFNetworking.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <CocoaSecurity/CocoaSecurity.h>
#import <Functional.m/F.h>

@implementation APIClient {

}

+ (APIClient *)sharedInstance {
	static APIClient *sharedInstance = nil;
	if (sharedInstance) return sharedInstance;
	static dispatch_once_t pred;
	dispatch_once(&pred, ^{
		sharedInstance = [[APIClient alloc] init];
	});
	return sharedInstance;
}

- (RACSignal *)getSessionForAccount:(EboksAccount *)account {
	EboksSession *session = [EboksSession new];
	session.deviceId = [NSString nextUUID];
	session.account = account;

	NSString *dateString = [APIClient currentDateString];
	NSString *input = [NSString stringWithFormat:@"%@:%@:P:%@:DK:%@:%@", account.activationCode, session.deviceId, account.userId, account.password, dateString];
	NSString *challenge = [APIClient doubleHash:input];
	NSURL *url = [NSURL URLWithString:@"https://rest.e-boks.dk/mobile/1/xml.svc/en-gb/session"];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	NSString *authHeader = [NSString stringWithFormat:@"logon deviceid=\"%@\",datetime=\"%@\",challenge=\"%@\"", session.deviceId, dateString, challenge];

	[request setValue:authHeader forHTTPHeaderField:@"X-EBOKS-AUTHENTICATE"];
	NSString *bodyString = [NSString stringWithFormat:
		 @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
		  "<Logon xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns=\"urn:eboks:mobile:1.0.0\">"
		  "<App version=\"1.4.1\" os=\"iOS\" osVersion=\"9.0.0\" Device=\"iPhone\" />"
		  "<User identity=\"%@\" identityType=\"P\" nationality=\"DK\" pincode=\"%@\"/>"
		  "</Logon>", account.userId, account.password];
	NSData *body = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
	[request setHTTPBody:body];
	[request setHTTPMethod:@"PUT"];
	[request setValue:@"application/xml" forHTTPHeaderField:@"Content-Type"];
	[request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
	[request setValue:@"eboks/35 CFNetwork/672.1.15 Darwin/14.0.0" forHTTPHeaderField:@"User-Agent"];

	AFHTTPRequestOperation *requestOperation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
	
#ifdef DEBUG
	AFSecurityPolicy *sec = [[AFSecurityPolicy alloc] init];
	[sec setAllowInvalidCertificates:YES];
	requestOperation.securityPolicy = sec;
#endif
	
	requestOperation.responseSerializer = [AFOnoResponseSerializer XMLResponseSerializer];
	RACSignal *requestSignal = [self signalForRequestOperation:requestOperation];

	RACSignal *sessionSignal = [requestSignal map:^id(ONOXMLDocument *responseDocument) {
		ONOXMLElement *userElement = responseDocument.rootElement.children.firstObject;
		session.name = [userElement valueForAttribute:@"name" inNamespace:nil];
		account.ownerName = session.name; // a little dirty
		session.internalUserId = [userElement valueForAttribute:@"userId" inNamespace:nil];
		NSDictionary *headers = [requestOperation.response allHeaderFields];
		NSString *authenticateResponse = headers[@"X-EBOKS-AUTHENTICATE"];
		session.sessionId = [[authenticateResponse firstMatchWithDetails:RX(@"sessionid=\\\"(([a-f0-9]|-)+)\\\"")].groups[1] value];
		session.nonce = [[authenticateResponse firstMatchWithDetails:RX(@"nonce=\\\"(([a-f0-9])+)\\\"")].groups[1] value];
		return session;
	}];

	return sessionSignal;
}

- (RACSignal *)getFoldersWithSessionId:(EboksSession *)session {
	NSString *urlString = [NSString stringWithFormat:@"https://rest.e-boks.dk/mobile/1/xml.svc/en-gb/%@/0/mail/folders", session.internalUserId];
	RACSignal *requestSignal = [self requestSignalForSession:session urlString:urlString xmlResponse:YES];
	RACSignal *foldersSignal = [requestSignal map:^id(ONOXMLDocument *responseDocument) {
		NSArray *folderElements = [responseDocument.rootElement children];
		NSArray *folders = [folderElements map:^id(ONOXMLElement *element) {
			return [EboksFolderInfo folderFromXMLElement:element];
		}];
		return folders;
	}];
	return foldersSignal;
}

- (RACSignal *)getFolderId:(NSString *)folderId session:(EboksSession *)session skip:(NSInteger)skip take:(NSInteger)take {
	NSString *inboxPathFormat = @"https://rest.e-boks.dk/mobile/1/xml.svc/en-gb/%@/0/mail/folder/%@?skip=%ld&take=%ld&latest=false";
	NSString *urlString = [NSString stringWithFormat:inboxPathFormat, session.internalUserId, folderId, skip, take];
	RACSignal *requestSignal = [self requestSignalForSession:session urlString:urlString xmlResponse:YES];
	RACSignal *folderSignal = [requestSignal map:^id(ONOXMLDocument *responseDocument) {
		NSArray *messageElements = [responseDocument.rootElement.children.firstObject children];
		NSArray *messages = [messageElements map:^id(ONOXMLElement *element) {
			return [MessageInfo messageFromXMLElement:element userId:session.account.userId];
		}];
		return messages;
	}];
	return folderSignal;
}

- (RACSignal *)getFileDataForMessageId:(NSString *)messageId session:(EboksSession *)session {
	NSString *contentPathFormat = @"https://rest.e-boks.dk/mobile/1/xml.svc/en-gb/%@/0/mail/folder/0/message/%@/content";
	NSString *urlString = [NSString stringWithFormat:contentPathFormat, session.internalUserId, messageId];
	RACSignal *requestSignal = [self requestSignalForSession:session urlString:urlString xmlResponse:NO];

	RACSignal *contentSignal = [requestSignal map:^id(id responseData) {
		return responseData;
	}];
	return contentSignal;

}

- (RACSignal *)requestSignalForSession:(EboksSession *)session urlString:(NSString *)urlString xmlResponse:(BOOL)xml {
	// we need defer here to avoid setting the nonce before last second
	return [RACSignal defer:^RACSignal * {
		NSURL *url = [NSURL URLWithString:urlString];
		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
		[APIClient setHeadersOnRequest:request session:session];

		AFHTTPRequestOperation *requestOperation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
		if (xml) {
			requestOperation.responseSerializer = [AFOnoResponseSerializer XMLResponseSerializer];
		}
		RACSignal *requestSignal = [[self signalForRequestOperation:requestOperation] doNext:^(id _) {
			NSDictionary *headers = [requestOperation.response allHeaderFields];
			NSString *authenticateResponse = headers[@"X-EBOKS-AUTHENTICATE"];
			session.nonce = [[authenticateResponse firstMatchWithDetails:RX(@"nonce=\\\"(([a-f0-9])+)\\\"")].groups[1] value];
		}];
		return requestSignal;
	}];
}

- (RACSignal *)signalForRequestOperation:(AFHTTPRequestOperation *)requestOperation {
	return [[RACSignal createSignal:^RACDisposable *(id <RACSubscriber> subscriber) {
		[requestOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
			[subscriber sendNext:responseObject];
			[subscriber sendCompleted];
		} failure:^(AFHTTPRequestOperation *operation, NSError *error) {
			[subscriber sendError:error];
			NSLog(@"Error: %@", error);
		}];
		[[NSOperationQueue mainQueue] addOperation:requestOperation];
		return [RACDisposable disposableWithBlock:^{
			[requestOperation cancel];
		}];
	}] logError];
}

+ (void)setHeadersOnRequest:(NSMutableURLRequest *)request session:(EboksSession *)session {
	NSString *signature = [NSString stringWithFormat:@"%@:%@:%@:%@", session.account.activationCode, session.deviceId, session.nonce, session.sessionId];
	NSString *responseChallenge = [APIClient doubleHash:signature];
	NSString *auth = [NSString stringWithFormat:@"deviceid=\"%@\",nonce=\"%@\",sessionid=\"%@\",response=\"%@\"", session.deviceId, session.nonce, session.sessionId, responseChallenge];
	[request setValue:auth forHTTPHeaderField:@"X-EBOKS-AUTHENTICATE"];
	[request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
	[request setValue:@"eboks/35 CFNetwork/672.1.15 Darwin/14.0.0" forHTTPHeaderField:@"User-Agent"];
}

+ (NSString *)currentDateString {
	return [[NSDate date] description];
}

+ (NSString *)sha256:(NSString *)input {
	return [CocoaSecurity sha256:input].hexLower;
}

+ (NSString *)doubleHash:(NSString *)input {
	return [self sha256:[self sha256:input]];
}


@end