#import <Foundation/Foundation.h>
#import "RtxModule.h"
#import <React/RCTLog.h>
#import <errno.h>

#ifdef __aarch64__ || __x86_64__
#import "RtxExportArm64.h"
#else
#import "../rtxnative/Rtx_export.framework/Headers/Rtx_export.h"
#endif

#import "QRCodeReaderViewController.h"
#import "AppDelegate.h"

@implementation RtxModule

RCT_EXPORT_MODULE()

// TODO: This is super ugly! but it kinda works because
// since Apple doesn't allow background processes, we don't need
// to do a "better" way of checking if LND is running since this
// will always be in memory while the app is in memory.
// But it's still worth getting something better.
BOOL lndProcessRunning = NO;

// We use delegates to scan QR codes, keep promise in static var to be able to call.
RCTPromiseResolveBlock qrCodeScanned = nil;
RCTPromiseRejectBlock qrCodeScanCancelled = nil;

RCT_EXPORT_METHOD(isLndProcessRunning:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
  // TODO: implement
  RCTLogInfo(@"isLndProcessRunning");
  resolve([NSNumber numberWithBool:lndProcessRunning]);
}

RCT_EXPORT_METHOD(getFilesDir:(RCTPromiseResolveBlock) resolve rejecter:(RCTPromiseRejectBlock)reject) {
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
  NSString *applicationSupportDirectory = [paths firstObject];
#ifdef DEBUG
  RCTLogInfo(@"getFilesDir: %@", applicationSupportDirectory);
#endif
  resolve(applicationSupportDirectory);
}

RCT_EXPORT_METHOD(readFile:(NSString *)fileName resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
#ifdef DEBUG
  RCTLogInfo(@"readFile: %@",fileName);
#endif
  NSError *error;
  NSString *strFileContent = [NSString stringWithContentsOfFile:fileName
                                       encoding:NSUTF8StringEncoding
                                       error:&error];
  if(error) {
#ifdef DEBUG
    RCTLogInfo(@"Reading failed with %@",error);
#endif
    resolve(@"");
  }else{
#ifdef DEBUG
    RCTLogInfo(@"Read %@",strFileContent);
#endif
    resolve(strFileContent);
  }
}

RCT_EXPORT_METHOD(writeFile:(NSString *)fileName content:(NSString*)content resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
#ifdef DEBUG
  RCTLogInfo(@"writeFile: %@",fileName);
#endif
  NSString *onlyPath = [fileName stringByDeletingLastPathComponent];
  [[NSFileManager defaultManager] createDirectoryAtPath:onlyPath withIntermediateDirectories:YES attributes:nil error:NULL];
  
  NSError *error;
  [content writeToFile:fileName atomically:NO encoding:NSUTF8StringEncoding error:&error];
  
  if(error != nil) {
#ifdef DEBUG
    RCTLogInfo(@"Writing failed with %@!", error);
#endif
    reject(@"error_write", @"Couldn't write file", error);
  }else{
#ifdef DEBUG
    RCTLogInfo(@"Wrote %@",content);
#endif
    resolve(@"success");
  }
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler
{
  if([challenge.protectionSpace.authenticationMethod
      isEqualToString:NSURLAuthenticationMethodServerTrust])
  {
    if([challenge.protectionSpace.host
        isEqualToString:@"localhost"])
    {
      // TODO: use SSL pinning to certs generated by lnd.
      NSURLCredential *credential =
      [NSURLCredential credentialForTrust:
       challenge.protectionSpace.serverTrust];
      completionHandler(NSURLSessionAuthChallengeUseCredential,credential);
    }
    else
      completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
  }
}

RCT_EXPORT_METHOD(fileExists:(NSString *)fileName
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  BOOL isDirectory;
  BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:fileName isDirectory:&isDirectory];
  BOOL exists = fileExists && !isDirectory;
  resolve([NSNumber numberWithBool:exists]);
}

RCT_EXPORT_METHOD(startLnd:(NSString *)lndDir
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *applicationSupportDirectory = [paths firstObject];
    
    char *err = InitLnd([lndDir UTF8String]);
    NSString *errStr = [NSString stringWithUTF8String:err];
    if(errStr != nil && [errStr length] > 0) {
      RCTLogInfo(@"Couldn't init lnd %s!",err);
    }
    NSString *lastRunningPath = [NSString stringWithFormat:@"%@/%@",applicationSupportDirectory,@"lastrunninglnddir.txt"];
    [lndDir writeToFile:lastRunningPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    lndProcessRunning = true;
    
    StartLnd();
  });
  
  // TODO: this is a hack to wait until lnd rpc servers are up.
  [NSThread sleepForTimeInterval:1.5];
  resolve(@"success");
}

RCT_EXPORT_METHOD(stopLnd:(NSString *)lndDir
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  RCTLogInfo(@"Stopping LND");
  GoUint8 stopResult = StopLnd();
  lndProcessRunning = NO;
  RCTLogInfo(@"Stop result, %i",stopResult);
  resolve(@"success");
}

RCT_EXPORT_METHOD(fetch:(NSDictionary *)request
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  NSString *urlPath = [request valueForKey:@"url"];
  
  NSURLSessionConfiguration *defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];
  [defaultConfigObject setRequestCachePolicy:NSURLRequestReloadIgnoringCacheData];
  [defaultConfigObject setURLCache:nil];
  NSDictionary *headers =[request objectForKey:@"headers"];
  if (headers != nil) {
    [defaultConfigObject setHTTPAdditionalHeaders:headers];
  }
  NSURLSession *session =[NSURLSession sessionWithConfiguration:defaultConfigObject delegate:self delegateQueue:[NSOperationQueue mainQueue]];
  id completionHandler =^(NSData *data, NSURLResponse *response, NSError *error) {
    if(error != nil) {
      RCTLogInfo(@"fetching %@ failed with: %@",urlPath, error);
      reject(@"fetch_failed", @"Couldn't fetch!", error);
    } else if(response != nil) {
      NSString *bodyString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      NSDictionary *jsResponse = [[NSDictionary alloc] initWithObjectsAndKeys:bodyString, @"bodyString", nil];
      resolve(jsResponse);
    }
  };
  NSURLSessionTask *task = nil;
  
  NSMutableURLRequest *urlRequest = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:urlPath]];
  NSString *method =[request objectForKey:@"method"];
  if (method == nil) {
    task = [session dataTaskWithRequest:urlRequest completionHandler:completionHandler];
  } else if ([[method lowercaseString] isEqualToString:@"post"]){
    NSData *data = nil;
    NSString *body = [request valueForKey:@"jsonBody"];
    data = [body dataUsingEncoding:NSUTF8StringEncoding];
    [urlRequest setHTTPMethod:@"POST"];
    task = [session uploadTaskWithRequest:urlRequest fromData:data completionHandler:completionHandler];
  }
  [task resume];
}

RCT_EXPORT_METHOD(encodeBase64:(NSString *)toConvert
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
#ifdef DEBUG
  RCTLogInfo(@"Encoding %@",toConvert);
#endif
  NSData *data = [toConvert dataUsingEncoding:NSUTF8StringEncoding];
  NSData *encoded = [data base64EncodedDataWithOptions:0];
  NSString *encodedString = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
#ifdef DEBUG
  RCTLogInfo(@"Encoded %@",encodedString);
#endif
  resolve(encodedString);
}

RCT_EXPORT_METHOD(getMacaroonHex:(NSString *)macaroonFile
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
#ifdef DEBUG
  RCTLogInfo(@"Getting macaroon for %@",macaroonFile);
#endif
  NSData *macaroon = [NSData dataWithContentsOfFile:macaroonFile];
  // Convert macaroon to hex.
  // TODO: super ugly, fix.
  
  const unsigned char *dataBuffer = (const unsigned char*)[macaroon bytes];
  if(!dataBuffer) {
    reject(@"no_macaroon",@"Couldn't find a macaroon to encode!",nil);
    return;
  }
  NSUInteger dataLength = [macaroon length];
  NSMutableString *hexString = [NSMutableString stringWithCapacity:(dataLength * 2)];
  for(int i = 0; i < dataLength; ++i) {
    [hexString appendFormat:@"%02x", (unsigned int)dataBuffer[i]];
  }
  NSString *hexEncoded = [NSString stringWithString:hexString];
#ifdef DEBUG
  RCTLogInfo(@"Macaroon for %@: %@", macaroonFile, hexEncoded);
#endif
  resolve(hexEncoded);
}

RCT_EXPORT_METHOD(scanQrCode: (RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
  if(![QRCodeReader isAvailable]) {
    reject(@"qrcode_scanner_not_available",@"QR Code scanner isn't available on this phone", nil);
  }
#ifdef DEBUG
  RCTLogInfo(@"Scanning QR Code!");
#endif
  QRCodeReader *reader = [QRCodeReader readerWithMetadataObjectTypes:@[AVMetadataObjectTypeQRCode]];
  QRCodeReaderViewController *vc = [QRCodeReaderViewController
                                    readerWithCancelButtonTitle:@"Cancel"
                                    codeReader:reader
                                    startScanningAtLoad:YES
                                    showSwitchCameraButton:YES
                                    showTorchButton:YES];
  vc.modalPresentationStyle = UIModalPresentationFormSheet;
  vc.delegate = self;
  AppDelegate *delegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
  
  // https://github.com/wkh237/react-native-fetch-blob/issues/168
  qrCodeScanned = resolve;
  qrCodeScanCancelled = reject;
  dispatch_sync(dispatch_get_main_queue(), ^{
    [delegate.window.rootViewController presentViewController:vc animated:YES completion:nil];
  });
}

- (void)reader:(QRCodeReaderViewController *)reader didScanResult:(NSString *)result
{
  AppDelegate *delegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
  [delegate.window.rootViewController dismissViewControllerAnimated:YES completion:^{
    if (result != nil && qrCodeScanned != nil){
#ifdef DEBUG
      RCTLogInfo(@"Scanned %@",result);
#endif
      qrCodeScanned(result);
    } else if (qrCodeScanCancelled != nil){
      qrCodeScanCancelled(@"qr_scan_cancelled", @"QR code scanning was cancelled!", nil);
    }
    qrCodeScanned = nil;
    qrCodeScanCancelled = nil;
  }];
}

- (void)readerDidCancel:(QRCodeReaderViewController *)reader
{
  AppDelegate *delegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
  [delegate.window.rootViewController dismissViewControllerAnimated:YES completion:^ {
    if(qrCodeScanCancelled != nil){
      qrCodeScanned(nil);
    }
    qrCodeScanned = nil;
    qrCodeScanCancelled = nil;
  }];
}

@end
