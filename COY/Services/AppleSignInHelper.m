//
//  AppleSignInHelper.m
//  COY
//
//  Helper for Apple Sign-in with Firebase Auth
//

#import "AppleSignInHelper.h"

// Import Firebase Auth - must import before using FIRAuthCredential class
@import FirebaseAuth;

@implementation AppleSignInHelper

+ (nullable FIRAuthCredential *)credentialWithProviderID:(NSString *)providerID
                                                idToken:(NSString *)idToken
                                               rawNonce:(NSString *)rawNonce {
    // Try to create credential using OAuthProvider class method
    // This avoids the fatal error from initializing OAuthProvider(providerID: "apple.com")
    Class oauthProviderClass = NSClassFromString(@"FIROAuthProvider");
    if (!oauthProviderClass) {
        oauthProviderClass = NSClassFromString(@"OAuthProvider");
    }
    
    if (oauthProviderClass) {
        SEL selector = NSSelectorFromString(@"credentialWithProviderID:idToken:rawNonce:");
        if ([oauthProviderClass respondsToSelector:selector]) {
            // Use NSInvocation for methods with multiple parameters
            NSMethodSignature *signature = [oauthProviderClass methodSignatureForSelector:selector];
            if (signature) {
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                invocation.target = oauthProviderClass;
                invocation.selector = selector;
                
                [invocation setArgument:&providerID atIndex:2];
                [invocation setArgument:&idToken atIndex:3];
                [invocation setArgument:&rawNonce atIndex:4];
                [invocation retainArguments];
                [invocation invoke];
                
                __unsafe_unretained id result = nil;
                [invocation getReturnValue:&result];
                
                if ([result isKindOfClass:[FIRAuthCredential class]]) {
                    return (FIRAuthCredential *)result;
                }
            }
        }
    }
    return nil;
}

+ (nullable FIRAuthCredential *)credentialWithProviderID:(NSString *)providerID
                                                idToken:(NSString *)idToken
                                               rawNonce:(NSString *)rawNonce
                                            accessToken:(NSString *)accessToken {
    // Try 4-parameter version
    Class oauthProviderClass = NSClassFromString(@"FIROAuthProvider");
    if (!oauthProviderClass) {
        oauthProviderClass = NSClassFromString(@"OAuthProvider");
    }
    
    if (oauthProviderClass) {
        SEL selector = NSSelectorFromString(@"credentialWithProviderID:idToken:rawNonce:accessToken:");
        if ([oauthProviderClass respondsToSelector:selector]) {
            // Use NSInvocation for methods with multiple parameters
            NSMethodSignature *signature = [oauthProviderClass methodSignatureForSelector:selector];
            if (signature) {
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                invocation.target = oauthProviderClass;
                invocation.selector = selector;
                
                [invocation setArgument:&providerID atIndex:2];
                [invocation setArgument:&idToken atIndex:3];
                [invocation setArgument:&rawNonce atIndex:4];
                [invocation setArgument:&accessToken atIndex:5];
                [invocation retainArguments];
                [invocation invoke];
                
                __unsafe_unretained id result = nil;
                [invocation getReturnValue:&result];
                
                if ([result isKindOfClass:[FIRAuthCredential class]]) {
                    return (FIRAuthCredential *)result;
                }
            }
        }
    }
    return nil;
}

@end

