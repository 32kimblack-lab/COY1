//
//  AppleSignInHelper.h
//  COY
//
//  Helper for Apple Sign-in with Firebase Auth
//

#import <Foundation/Foundation.h>

// Forward declaration - we'll import the full header in the .m file
@class FIRAuthCredential;

NS_ASSUME_NONNULL_BEGIN

@interface AppleSignInHelper : NSObject

+ (nullable FIRAuthCredential *)credentialWithProviderID:(NSString *)providerID
                                                idToken:(NSString *)idToken
                                               rawNonce:(NSString *)rawNonce;

+ (nullable FIRAuthCredential *)credentialWithProviderID:(NSString *)providerID
                                                idToken:(NSString *)idToken
                                               rawNonce:(NSString *)rawNonce
                                            accessToken:(NSString *)accessToken;

@end

NS_ASSUME_NONNULL_END

