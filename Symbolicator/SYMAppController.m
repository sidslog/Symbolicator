//
//  SYMAppController.m
//  Symbolicator
//
//  Created by Sam Stigler on 3/13/14.
//  Copyright (c) 2014 Sam Stigler. All rights reserved.
//

#import "SYMAppController.h"
#import "SYMLocator.h"
#import "SYMSymbolicator.h"
#import "SYMCache.h"

NSString *const kSearchDirectory = @"kSearchDirectory";

@interface SYMAppController ()

- (IBAction)chooseCrashReport:(id)sender;
- (IBAction)chooseDSYM:(id)sender;
- (IBAction)findDSYMFile:(id)sender;
- (IBAction)export:(id)sender;

@end

@implementation SYMAppController


- (instancetype) init {
    if (self = [super init]) {
        NSString *searchFolderPath = [[NSUserDefaults standardUserDefaults] objectForKey:kSearchDirectory];
        if (searchFolderPath) {
            self.dSYMURL = [NSURL fileURLWithPath:searchFolderPath];
            [SYMCache cacheFodler:self.dSYMURL];
        }
        [self updateStatus];
    }
    return self;
}

- (void)chooseCrashReport:(id)sender
{
    __weak typeof(self) weakSelf = self;
    
    NSOpenPanel* reportChooser = [self fileChooserWithMessage:@"Which crash report is it?" fileType:@"crash"];
    [reportChooser
     beginSheetModalForWindow:[NSApp mainWindow]
     completionHandler:^(NSInteger result) {
         if (result == NSFileHandlingPanelOKButton)
         {
             weakSelf.crashReportURL = [reportChooser URL];
             [weakSelf updateStatus];
         }
     }];
}

- (void)chooseDSYM:(id)sender
{
    __weak typeof(self) weakSelf = self;
    
    NSOpenPanel* chooser = [self fileChooserWithMessage:@"Select dSYM file or a folder which contains dSYM file" fileType:nil];
    [chooser
     beginSheetModalForWindow:[NSApp mainWindow]
     completionHandler:^(NSInteger result) {
         if (result == NSFileHandlingPanelOKButton)
         {
             NSURL *url = chooser.URL;
             if (![url.pathExtension isEqualToString:@"dSYM"]) {
                 [[NSUserDefaults standardUserDefaults] setObject:url.path forKey:kSearchDirectory];
                 [[NSUserDefaults standardUserDefaults] synchronize];
                 [SYMCache cacheFodler:url];
             }
             weakSelf.dSYMURL = [chooser URL];
             [weakSelf updateStatus];
         }
     }];
}

- (void) findDSYMFile:(id) sender {
    [self setEnabled:NO withStatusString:@"Searching for dSYM file..."];
    __weak typeof(self) weakSelf = self;
    
    [SYMLocator findDSYMWithPlistUrl:self.crashReportURL inFolder:self.dSYMURL completion:^(NSURL * dSYMURL, NSString *version) {
        if (dSYMURL) {
            [weakSelf symbolicate:dSYMURL version:version];
        } else {
            [weakSelf setEnabled:NO withStatusString:[NSString stringWithFormat:@"dSYM file not found for app version: %@", version]];
        }
    }];
}

- (void) copyFilesToCrashesDirectoryWithVersion: (NSString *) version completion: (void (^)(NSURL *crashURL, NSURL *dSYMURL)) completion {
    
    NSAssert(self.crashReportURL, @"No crash report URL");
    NSAssert(self.dSYMURL, @"No dSYM URL");
    NSAssert(version, @"No version");
    
    __weak typeof(self) this = self;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSURL *appURL = [[self.dSYMURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
        appURL = [[appURL URLByAppendingPathComponent:@"Products"] URLByAppendingPathComponent:@"Applications"];
        
        NSError *error = nil;
        NSString *appName = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:appURL.path error:&error] firstObject];
        
        if (appName) {
            appURL = [appURL URLByAppendingPathComponent:appName];
            NSURL *docDir = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *crashesURL = [[docDir URLByAppendingPathComponent:@"Crashes"] URLByAppendingPathComponent:version];
            
            if (![[NSFileManager defaultManager] fileExistsAtPath:crashesURL.path]) {
                [[NSFileManager defaultManager] createDirectoryAtURL:crashesURL withIntermediateDirectories:true attributes:nil error:&error];
            }
            
            NSURL *tempCrashURL = [crashesURL URLByAppendingPathComponent:self.crashReportURL.lastPathComponent];
            NSURL *tempDSYMURL = [crashesURL URLByAppendingPathComponent:[appName stringByAppendingString:@".dSYM"]];
            NSURL *tempAppURL = [crashesURL URLByAppendingPathComponent:appName];
            error = nil;
            
            if (appName) {
                [[NSFileManager defaultManager] copyItemAtURL:appURL toURL:tempAppURL error:&error];
            }
            [[NSFileManager defaultManager] copyItemAtURL:self.dSYMURL toURL:tempDSYMURL error:&error];
            [[NSFileManager defaultManager] copyItemAtURL:self.crashReportURL toURL:tempCrashURL error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(tempCrashURL, tempDSYMURL);
            });

        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(this.crashReportURL, this.dSYMURL);
            });
        }
        
    });
}

- (void)symbolicate:(NSURL *) dSYMURL version: (NSString *) version
{
    [self setEnabled:NO withStatusString:@"Symbolication in process..."];
    __weak typeof(self) weakSelf = self;
    
    self.dSYMURL = dSYMURL;
    
    [self copyFilesToCrashesDirectoryWithVersion:version completion:^(NSURL *crashURL, NSURL *dSYMURL) {
        [SYMSymbolicator
         symbolicateCrashReport:crashURL
         dSYM:dSYMURL
         withCompletionBlock:^(NSString *symbolicatedReport) {
             weakSelf.symbolicatedReport = symbolicatedReport;
             NSString *status = [NSString stringWithFormat:@"Symbolicate (%@)", dSYMURL];
             [weakSelf setEnabled:YES withStatusString:status];
         }];
    }];
    
}


- (void)export:(id)sender
{
    __weak typeof(self) weakSelf = self;
    
    NSSavePanel* exportSheet = [self exportSheet];
    [exportSheet
     beginSheetModalForWindow:[NSApp mainWindow]
     completionHandler:^(NSInteger result) {
         if (result == NSFileHandlingPanelOKButton)
         {
             dispatch_queue_t concurrentQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
             dispatch_async(concurrentQueue, ^{
                 NSError* error = nil;
                 BOOL success = [weakSelf.symbolicatedReport
                                 writeToURL:exportSheet.URL
                                 atomically:NO
                                 encoding:NSUTF8StringEncoding
                                 error:&error];
                 
                 if ((success == NO) &&
                     (error != nil))
                 {
                     [weakSelf showAlertForError:error];
                 }
             });
         }
     }];
}

- (NSOpenPanel *)fileChooserWithMessage:(NSString *)message fileType:(NSString *)extension
{
    NSOpenPanel* openPanel = [NSOpenPanel openPanel];
    [openPanel setCanChooseDirectories:extension ? NO : YES];
    [openPanel setCanChooseFiles:YES];
    [openPanel setAllowsMultipleSelection:NO];
    if (extension) {
        [openPanel setAllowedFileTypes:@[extension]];
    }
    [openPanel setCanCreateDirectories:NO];
    [openPanel setPrompt:@"Choose"];
    [openPanel setMessage:message];
    [openPanel setTreatsFilePackagesAsDirectories:YES];
    return openPanel;
}


- (NSSavePanel *)exportSheet
{
    NSSavePanel* savePanel = [NSSavePanel savePanel];
    [savePanel setTitle:@"Export"];
    [savePanel setPrompt:@"Export"];
    [savePanel setAllowedFileTypes:@[@"crash"]];
    [savePanel setTreatsFilePackagesAsDirectories:NO];
    [savePanel setExtensionHidden:NO];
    return savePanel;
}

- (void) updateStatus {
    if (self.dSYMURL && self.crashReportURL) {
        NSString *statusString;
        if ([[self.dSYMURL pathExtension] isEqualToString:@"dSYM"]) {
            statusString = @"Symbolicate";
        } else {
            statusString = @"Search for the dSYM file";
        }
        [self setEnabled:YES withStatusString:statusString];
    } else {
        [self setEnabled:NO withStatusString:@"Select crash report and a folder with dSYMs or concrete dSYM file."];
    }
}

- (void) setEnabled: (BOOL) enabled withStatusString: (NSString *) string {
    self.canSymbolicate = enabled;
    self.symbolicateStatus = string;
}

- (void)showAlertForError:(NSError *)error
{
    NSParameterAssert(error != nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [NSAlert alertWithError:error];
        [alert runModal];
    });
}

@end
