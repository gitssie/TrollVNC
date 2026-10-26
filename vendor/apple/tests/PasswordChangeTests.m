#import "../src/appleid/TVApplePasswordChange.m"
#include <assert.h>
NSDictionary *TVAppleNativeAuthenticateAutomatic(NSString *appleID,NSString *password,id<TVAppleVerificationCodeProvider> provider,NSError **error){(void)appleID;(void)password;(void)provider;*error=TVAppleError(TVAppleErrorUnsupported,@"Test authentication unavailable.");return nil;}
BOOL TVAppleValidateLocalPasscode(NSString *passcode,NSError **error){(void)passcode;*error=TVAppleError(TVAppleErrorUnsupported,@"Test local secret unavailable.");return NO;}
@interface RUIElement:NSObject
@property NSDictionary *attributes;
@end
@implementation RUIElement
- (id)initWithAttributes:(id)attributes parent:(id)parent{(void)parent;if((self=[super init]))self.attributes=attributes;return self;}
@end
@interface PasswordRow:NSObject
@property NSDictionary *attributes;
@property NSString *value;
@end
@implementation PasswordRow
- (id)tableCell{return self;}
- (void)setValueFromString:(id)value notify:(BOOL)notify{(void)notify;self.value=value;}
- (void)setEditableTextFieldValue:(id)value{self.value=value;}
@end
@interface PasswordModel:NSObject {
@public NSDictionary *_namedAlerts;
}
@property NSDictionary *clientInfo;
@property NSArray *rows;
@property RUIElement *save;
@property BOOL validation;
@property NSUInteger submissions;
@property NSDictionary *submittedAttributes;
@end
@implementation PasswordModel
- (id)allPages{return @[self];}
- (id)tableViewOM{return self;}
- (id)sections{return @[self];}
- (id)rightNavigationBarButtonItem{return self.save;}
- (id)postbackDictionary{NSMutableDictionary *body=[NSMutableDictionary new];for(PasswordRow *row in self.rows)if(row.value)body[row.attributes[@"id"]]=row.value;return body;}
- (BOOL)validateWithFunction:(id)function{(void)function;return self.validation;}
- (void)alertView:(id)alert pressedButton:(id)button completion:(void (^)(void))completion{assert(alert==self->_namedAlerts[@"signoutDevices"]);self.submissions++;self.submittedAttributes=[button attributes];completion();}
@end
static TVApplePasswordSession *Session(void){
    TVApplePasswordSession *s=[TVApplePasswordSession new];s.done=dispatch_semaphore_create(0);s.oldPassword=@"Original123";s.candidate=@"Mix123Ab";s.origin=[NSURL URLWithString:@"https://account.example.test/appleid/settings/account/manage/security"];
    s.raw=[@"<xmlui><alert id='signoutDevices'><button name='ak-button' ak-action='read' httpMethod='POST' url='https://account.example.test/appleid/settings/account/manage/security/password/signout/put'/><button name='ak-button' ak-action='read' httpMethod='POST' url='https://account.example.test/appleid/settings/account/manage/security/password/put'/></alert></xmlui>" dataUsingEncoding:NSUTF8StringEncoding];return s;
}
static PasswordModel *Form(BOOL current){
    PasswordModel *m=[PasswordModel new];m.validation=YES;m->_namedAlerts=@{@"signoutDevices":[NSObject new]};
    NSMutableDictionary *info=[@{@"newPasswordRowId":@"newPassword.password"}mutableCopy];if(current)info[@"currentPasswordRowId"]=@"password";m.clientInfo=info;
    NSMutableArray *rows=[NSMutableArray new];for(NSString *key in current?@[@"password",@"newPassword.password",@"newPassword.confirmedPassword"]:@[@"newPassword.password",@"newPassword.confirmedPassword"]){PasswordRow *row=[PasswordRow new];row.attributes=@{@"id":key,@"class":@"editableText"};[rows addObject:row];}m.rows=rows;
    m.save=[RUIElement new];m.save.attributes=@{@"name":@"ak-button",@"ak-action":@"read",@"url":@"#signoutDevices",@"validationFunction":@"validate"};return m;
}
int main(void){@autoreleasepool{
    assert(TVAppleValidNewPassword(@"Mix123Ab"));for(id value in @[@"abcdef12",@"ABCDEF12",@"AbCdEfGh",@"Ab1!defg",@"Ab1234567",@"Ａb123456",@7])assert(!TVAppleValidNewPassword(value));
    assert(TrueFlag(@YES)&&TrueFlag(@1)&&TrueFlag(@"true")&&TrueFlag(@"1"));assert(!TrueFlag(@NO)&&!TrueFlag(@2)&&!TrueFlag(@"false")&&!TrueFlag(NSNull.null));
    for(NSNumber *current in @[@NO,@YES]){
        TVApplePasswordSession *s=Session();PasswordModel *m=Form(current.boolValue);[s submit:m];
        assert(m.submissions==1&&s.submitted&&!s.closed);assert([m.submittedAttributes[@"url"]hasSuffix:@"/password/put"]);assert(![m.submittedAttributes[@"url"]containsString:@"/signout/"]);
        NSDictionary *body=[m postbackDictionary];assert([body[@"newPassword.password"]isEqual:@"Mix123Ab"]);assert([body[@"newPassword.confirmedPassword"]isEqual:@"Mix123Ab"]);assert(body.count==(current.boolValue?3:2));
        PasswordModel *success=[PasswordModel new];success.clientInfo=@{@"passwordUpdated":@1};[s receive:success];assert(s.closed&&[s.result[@"password_changed"]isEqual:@YES]);assert(!s.candidate&&!s.oldPassword);assert(![[s.result description]containsString:@"Mix123Ab"]);
    }
    {
        TVApplePasswordSession *s=Session();PasswordModel *m=Form(NO);m.validation=NO;[s submit:m];assert(m.submissions==0&&s.closed&&!s.submitted&&s.failure.code==TVAppleErrorInvalidRequest);
    }
    {
        TVApplePasswordSession *s=Session();s.raw=[@"<xmlui><alert id='signoutDevices'><button name='ak-button' ak-action='read' httpMethod='POST' url='/appleid/settings/account/manage/security/password/put'/><button name='ak-button' ak-action='read' httpMethod='POST' url='/appleid/settings/account/manage/security/password/put'/></alert></xmlui>" dataUsingEncoding:NSUTF8StringEncoding];PasswordModel *m=Form(NO);[s submit:m];assert(s.closed&&m.submissions==0);
    }
    {
        TVApplePasswordSession *s=Session();s.raw=[@"<xmlui><alert id='other'><button name='ak-button' ak-action='read' httpMethod='POST' url='/appleid/settings/account/manage/security/password/put'/></alert></xmlui>" dataUsingEncoding:NSUTF8StringEncoding];PasswordModel *m=Form(NO);[s submit:m];assert(s.closed&&m.submissions==0);
    }
    {
        TVApplePasswordSession *s=Session();s.remote=[NSObject new];[s fail:TVAppleError(TVAppleErrorUnsupported,@"Unsupported loader")];assert(s.closed);
    }
    puts("PASS native password form: two/three rows, named alert keep action, explicit flag types, validation, duplicate/foreign buttons, unsupported cleanup, credential-free completion");
}return 0;}
