/*

 AdViewAdapterCustom.m

 Copyright 2010 www.adview.cn

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

#import "AdViewAdapterCustom.h"
#import "AdViewViewImpl.h"
#import "AdViewLog.h"
#import "AdViewConfig.h"
#import "AdViewAdNetworkConfig.h"
#import "AdViewError.h"
#import "CJSONDeserializer.h"
#import "AdViewCustomAdView.h"
#import "AdViewAdNetworkAdapter+Helpers.h"
#import "AdViewAdNetworkRegistry.h"

@interface AdViewAdapterCustom ()

- (BOOL)parseAdData:(NSData *)data error:(NSError **)error;

@property (nonatomic,readonly) CLLocationManager *locationManager;
@property (nonatomic,retain) NSURLConnection *adConnection;
@property (nonatomic,retain) NSURLConnection *imageConnection;
@property (nonatomic,retain) AdViewCustomAdView *adView;
@property (nonatomic,retain) AdViewWebBrowserController *webBrowserController;

@end


@implementation AdViewAdapterCustom

@synthesize adConnection;
@synthesize imageConnection;
@synthesize adView;
@synthesize webBrowserController;

+ (AdViewAdNetworkType)networkType {
  return AdViewAdNetworkTypeCustom;
}

+ (void)load {
  [[AdViewAdNetworkRegistry sharedRegistry] registerClass:self];
}

- (id)initWithAdViewDelegate:(id<AdViewDelegate>)delegate
                           view:(AdViewView *)view
                         config:(AdViewConfig *)config
                  networkConfig:(AdViewAdNetworkConfig *)netConf {
  self = [super initWithAdViewDelegate:delegate
                                   view:view
                                 config:config
                          networkConfig:netConf];
  if (self != nil) {
    adData = [[NSMutableData alloc] init];
    imageData = [[NSMutableData alloc] init];
  }
  return self;
}

- (BOOL)shouldSendExMetric {
  return NO; // since we are getting the ad from the AdView server anyway, no
             // need to send extra metric ping to the same server.
}

- (void)getAd {
  @synchronized(self) {
    if (requesting) return;
    requesting = YES;
  }

  NSURL *adRequestBaseURL = nil;
#if ALL_ORG_DELEGATE_METHODS			//2010.12.24, laizhiwen	
  if ([adViewDelegate respondsToSelector:@selector(adViewCustomAdURL)]) {
    adRequestBaseURL = [adViewDelegate adViewCustomAdURL];
  }
#endif
  if (adRequestBaseURL == nil) {
    adRequestBaseURL = [NSURL URLWithString:kAdViewDefaultCustomAdURL];
  }
  NSString *query;
  if (adViewConfig.locationOn) {
    AWLogInfo(@"Allow location access in custom ad");
    CLLocation *location;
#if ALL_ORG_DELEGATE_METHODS
    if ([adViewDelegate respondsToSelector:@selector(locationInfo)]) {
      location = [adViewDelegate locationInfo];
    }
    else {
      location = [self.locationManager location];
    }
#else
	  location = [self.locationManager location];	  
#endif
    NSString *locationStr = [NSString stringWithFormat:@"%lf,%lf",
                             location.coordinate.latitude,
                             location.coordinate.longitude];
    query = [NSString stringWithFormat:@"?appver=%d&country_code=%@&appid=%@&nid=%@&location=%@&location_timestamp=%lf&client=1",
             KADVIEW_APP_VERSION,
             [[NSLocale currentLocale] localeIdentifier],
             adViewConfig.appKey,
             networkConfig.nid,
             locationStr,
             [[NSDate date] timeIntervalSince1970]];
  }
  else {
    AWLogInfo(@"Do not allow location access in custom ad");
    query = [NSString stringWithFormat:@"?appver=%d&country_code=%@&appid=%@&nid=%@&client=1",
             KADVIEW_APP_VERSION,
             [[NSLocale currentLocale] localeIdentifier],
             adViewConfig.appKey,
             networkConfig.nid];
  }
  NSURL *adRequestURL = [NSURL URLWithString:query relativeToURL:adRequestBaseURL];
  AWLogInfo(@"Requesting custom ad at %@", adRequestURL);
  NSURLRequest *adRequest = [NSURLRequest requestWithURL:adRequestURL];
  NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:adRequest
                                                          delegate:self];
  self.adConnection = conn;
  [conn release];
}

- (void)stopBeingDelegate {
  AdViewCustomAdView *theAdView = (AdViewCustomAdView *)self.adNetworkView;
  if (theAdView != nil) {
    theAdView.delegate = nil;
  }
}

- (void)dealloc {
  [locationManager release], locationManager = nil;
  [adConnection release], adConnection = nil;
  [adData release], adData = nil;
  [imageConnection release], imageConnection = nil;
  [imageData release], imageData = nil;
  [adView release], adView = nil;
  [webBrowserController release], webBrowserController = nil;
  [super dealloc];
}


- (CLLocationManager *)locationManager {
  if (locationManager == nil) {
    locationManager = [[CLLocationManager alloc] init];
  }
  return locationManager;
}

- (BOOL)parseEnums:(int *)val
            adInfo:(NSDictionary*)info
            minVal:(int)min
            maxVal:(int)max
         fieldName:(NSString *)name
             error:(NSError **)error {
  NSString *str = [info objectForKey:name];
  if (str == nil) {
    if (error != nil)
      *error = [AdViewError errorWithCode:AdViewCustomAdDataError
                               description:[NSString stringWithFormat:
                                            @"Custom ad data has no '%@' field", name]];
    return NO;
  }
  int intVal = [str intValue];
  if (intVal <= min || intVal >= max) {
    if (error != nil)
      *error = [AdViewError errorWithCode:AdViewCustomAdDataError
                               description:[NSString stringWithFormat:
                                            @"Custom ad: Invalid value for %@ - %d", name, intVal]];
    return NO;
  }
  *val = intVal;
  return YES;
}

- (BOOL)parseAdData:(NSData *)data error:(NSError **)error {
  NSError *jsonError = nil;
  id parsed = [[CJSONDeserializer deserializer] deserialize:data error:&jsonError];
  if (parsed == nil) {
    if (error != nil)
      *error = [AdViewError errorWithCode:AdViewCustomAdParseError
                               description:@"Error parsing custom ad JSON from server"
                           underlyingError:jsonError];
    return NO;
  }
  if ([parsed isKindOfClass:[NSDictionary class]]) {
    NSDictionary *adInfo = parsed;

    // gather up and validate ad info
    NSString *text = [adInfo objectForKey:@"ad_text"];
    NSString *redirectURLStr = [adInfo objectForKey:@"redirect_url"];

    int adTypeInt;
    if (![self parseEnums:&adTypeInt
                   adInfo:adInfo
                   minVal:AWCustomAdTypeMIN
                   maxVal:AWCustomAdTypeMAX
                fieldName:@"ad_type"
                    error:error]) {
      return NO;
    }
    AWCustomAdType adType = adTypeInt;

    int launchTypeInt;
    if (![self parseEnums:&launchTypeInt
                   adInfo:adInfo
                   minVal:AWCustomAdLaunchTypeMIN
                   maxVal:AWCustomAdLaunchTypeMAX
                fieldName:@"launch_type"
                    error:error]) {
      return NO;
    }
    AWCustomAdLaunchType launchType = launchTypeInt;

    int animTypeInt;
    if (![self parseEnums:&animTypeInt
                   adInfo:adInfo
                   minVal:AWCustomAdWebViewAnimTypeMIN
                   maxVal:AWCustomAdWebViewAnimTypeMAX
                fieldName:@"webview_animation_type"
                    error:error]) {
      return NO;
    }
    AWCustomAdWebViewAnimType animType = animTypeInt;

    NSURL *redirectURL = nil;
    if (redirectURLStr == nil) {
      AWLogWarn(@"No redirect URL for custom ad");
    }
    else {
      redirectURL = [[NSURL alloc] initWithString:redirectURLStr];
      if (!redirectURL)
        AWLogWarn(@"Custom ad: Malformed redirect URL string %@", redirectURLStr);
    }

    NSString *clickMetricsURLStr = [adInfo objectForKey:@"metrics_url"];
    NSURL *clickMetricsURL = nil;
    if (clickMetricsURLStr == nil) {
      AWLogWarn(@"No click metric URL for custom ad");
    }
    else {
      clickMetricsURL = [[NSURL alloc] initWithString:clickMetricsURLStr];
      if (!clickMetricsURL)
        AWLogWarn(@"Malformed click metrics URL string %@", clickMetricsURLStr);
    }

    AWLogInfo(@"Got custom ad '%@' %@ %@ %d %d %d", text, redirectURL,
               clickMetricsURL, adType, launchType, animType);

    self.adView = [[AdViewCustomAdView alloc] initWithDelegate:self
                                                           text:text
                                                    redirectURL:redirectURL
                                                clickMetricsURL:clickMetricsURL
                                                         adType:adType
                                                     launchType:launchType
                                                       animType:animType
                                                backgroundColor:[self helperBackgroundColorToUse]
                                                      textColor:[self helperTextColorToUse]];
    [self.adView release];
    self.adNetworkView = adView;
    [redirectURL release];
    [clickMetricsURL release];
    if (adView == nil) {
      if (error != nil)
        *error = [AdViewError errorWithCode:AdViewCustomAdDataError
                                 description:@"Error initializing AdView custom ad view"];
      return NO;
    }

    // fetch image
    NSString * imageURL = [adInfo objectForKey:@"img_url"];
    AWLogInfo(@"Request custom ad image at %@", imageURL);
    NSURLRequest *imageRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:imageURL]];
    NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:imageRequest
                                                            delegate:self];
    self.imageConnection = conn;
    [conn release];
  }
  else {
    if (error != nil)
      *error = [AdViewError errorWithCode:AdViewCustomAdDataError
                               description:@"Expected top-level dictionary in custom ad data"];
    return NO;
  }
  return YES;
}


#pragma mark NSURLConnection delegate methods.

- (void)connection:(NSURLConnection *)conn didReceiveResponse:(NSURLResponse *)response {
  if (conn == adConnection) {
    [adData setLength:0];
  }
  else if (conn == imageConnection) {
    [imageData setLength:0];
  }
}

- (void)connection:(NSURLConnection *)conn didFailWithError:(NSError *)error {
  if (conn == adConnection) {
    [adViewView adapter:self didFailAd:[AdViewError errorWithCode:AdViewCustomAdConnectionError
                                                   description:@"Error connecting to custom ad server"
                                               underlyingError:error]];
    requesting = NO;
  }
  else if (conn == imageConnection) {
    [adViewView adapter:self didFailAd:[AdViewError errorWithCode:AdViewCustomAdConnectionError
                                                        description:@"Error connecting to custom ad server to fetch image"
                                                    underlyingError:error]];
    requesting = NO;
  }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)conn {
  if (conn == adConnection) {
    NSError *error = nil;
    if (![self parseAdData:adData error:&error]) {
      [adViewView adapter:self didFailAd:error];
      requesting = NO;
      return;
    }
  }
  else if (conn == imageConnection) {
    UIImage *image = [[UIImage alloc] initWithData:imageData];
    if (image == nil) {
      [adViewView adapter:self didFailAd:[AdViewError errorWithCode:AdViewCustomAdImageError
                                                          description:@"Cannot initialize custom ad image from data"]];
      requesting = NO;
      return;
    }
    adView.image = image;
    [adView setNeedsDisplay];
    [image release];
    requesting = NO;
    [adViewView adapter:self didReceiveAdView:self.adView];
  }
}

- (void)connection:(NSURLConnection *)conn didReceiveData:(NSData *)data {
  if (conn == adConnection) {
    [adData appendData:data];
  }
  else if (conn == imageConnection) {
    [imageData appendData:data];
  }
}


#pragma mark AdViewCustomAdViewDelegate methods

- (void)adTapped:(AdViewCustomAdView *)ad {
  if (ad != adView) return;
  if (ad.clickMetricsURL != nil) {
    NSURLRequest *metRequest = [NSURLRequest requestWithURL:ad.clickMetricsURL];
    [NSURLConnection connectionWithRequest:metRequest
                                  delegate:nil]; // fire and forget
    AWLogInfo(@"Sent custom ad click ping to %@", ad.clickMetricsURL);
  }
  if (ad.redirectURL == nil) {
    AWLogError(@"Custom ad redirect URL is nil");
    return;
  }
  switch (ad.launchType) {
    case AWCustomAdLaunchTypeSafari:
      AWLogInfo(@"Opening URL '%@' for custom ad", ad.redirectURL);
      if ([[UIApplication sharedApplication] openURL:ad.redirectURL] == NO) {
        AWLogError(@"Cannot open URL '%@' for custom ad", ad.redirectURL);
      }
      break;
    case AWCustomAdLaunchTypeCanvas:
      if (self.webBrowserController == nil) {
        AdViewWebBrowserController *ctrlr = [[AdViewWebBrowserController alloc] init];
        self.webBrowserController = ctrlr;
        [ctrlr release];
      }
      webBrowserController.delegate = self;
      [webBrowserController presentWithController:[adViewDelegate viewControllerForPresentingModalView]
                                       transition:ad.animType];
      [self helperNotifyDelegateOfFullScreenModal];
      [webBrowserController loadURL:ad.redirectURL];
      break;
    default:
      AWLogError(@"Custom ad: Unsupported launch type %d", ad.launchType);
      break;
  }
}


#pragma mark AdViewWebBrowserControllerDelegate methods

- (void)webBrowserClosed:(AdViewWebBrowserController *)controller {
  if (controller != webBrowserController) return;
  self.webBrowserController = nil; // don't keep around to save memory
  [self helperNotifyDelegateOfFullScreenModalDismissal];
}

@end

