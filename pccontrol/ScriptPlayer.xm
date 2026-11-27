#import "ScriptPlayer.h"
#include <roothide.h>
#include "Play.h"
#include "SocketServer.h"
#include "Process.h"
#include "Task.h"
#include "Touch.h"
#include "AlertBox.h"
#include "Config.h"
#include "Common.h"
#import <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>
#include <limits.h>

static BOOL isPlaying = false;

static NSString *ZXShellQuote(NSString *value)
{
    if (!value) return @"''";
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *ZXFirstExecutablePath(NSArray<NSString *> *candidates)
{
    // zxPathLooksExecutable deliberately avoids isExecutableFileAtPath:, which
    // reports NO inside SpringBoard on iOS 18 even for an installed, mode 0755
    // interpreter. See the comment on it in Common.xm.
    for (NSString *path in candidates) {
        if (path.length > 0 && zxPathLooksExecutable(path.fileSystemRepresentation)) {
            return path;
        }
    }
    return nil;
}

static NSArray<NSString *> *ZXPythonCandidates(void)
{
    // Prefer specific versions before the generic `python3` symlink. If a
    // previous install of ZXTouch (or another package) pointed `python3` at a
    // broken interpreter (e.g. Procursus 3.7 whose libpython lives at a path
    // dyld can't resolve on rootless), a versioned binary is more likely to
    // actually load. 3.7 is dropped entirely — it aborts at dyld on 15+.
    return @[
        jbroot(@"/usr/bin/python3.12"),
        jbroot(@"/usr/bin/python3.11"),
        jbroot(@"/usr/bin/python3.10"),
        jbroot(@"/usr/bin/python3.9"),
        jbroot(@"/usr/bin/python3.8"),
        jbroot(@"/usr/bin/python3"),
        @"/var/jb/usr/bin/python3.12",
        @"/var/jb/usr/bin/python3.11",
        @"/var/jb/usr/bin/python3.10",
        @"/var/jb/usr/bin/python3.9",
        @"/var/jb/usr/bin/python3.8",
        @"/var/jb/usr/bin/python3",
        @"/usr/bin/python3.12",
        @"/usr/bin/python3.11",
        @"/usr/bin/python3.10",
        @"/usr/bin/python3.9",
        @"/usr/bin/python3.8",
        @"/usr/bin/python3"
    ];
}

static NSString *ZXPythonPath(void)
{
    return ZXFirstExecutablePath(ZXPythonCandidates());
}

// Describe one candidate precisely enough to tell "the file is not there" apart
// from "the file is there and this process is not allowed to see it". Those look
// identical through isExecutableFileAtPath:, which is why a device with python3
// plainly installed could still report it missing with nothing to go on.
static NSString *ZXDescribePath(NSString *path)
{
    if (path.length == 0) return @"(empty path)";

    const char *cpath = [path fileSystemRepresentation];
    struct stat st;
    if (lstat(cpath, &st) != 0) {
        return [NSString stringWithFormat:@"%@ -> MISSING (%s)", path, strerror(errno)];
    }

    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ -> mode=%04o", path, st.st_mode & 07777];

    if ((st.st_mode & S_IFMT) == S_IFLNK) {
        char target[PATH_MAX];
        ssize_t n = readlink(cpath, target, sizeof(target) - 1);
        if (n > 0) {
            target[n] = '\0';
            [line appendFormat:@" symlink->%s", target];
            struct stat tst;
            [line appendString:(stat(cpath, &tst) == 0) ? @" (target ok)" : @" (TARGET BROKEN)"];
        }
    }

    [line appendFormat:@" exec=%@", access(cpath, X_OK) == 0 ? @"yes" : [NSString stringWithFormat:@"no(%s)", strerror(errno)]];
    [line appendFormat:@" read=%@", access(cpath, R_OK) == 0 ? @"yes" : [NSString stringWithFormat:@"no(%s)", strerror(errno)]];
    [line appendFormat:@" nsexec=%@", [[NSFileManager defaultManager] isExecutableFileAtPath:path] ? @"yes" : @"no"];
    return line;
}

// Built only when the lookup has already failed, so it costs nothing normally.
static NSString *ZXPythonDiagnostics(void)
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"ZXTouch: no usable python3 found. Interpreter search:"];
    [lines addObject:[NSString stringWithFormat:@"  jbroot(\"/usr/bin\") = %@", jbroot(@"/usr/bin")]];

    for (NSString *candidate in ZXPythonCandidates()) {
        [lines addObject:[@"  " stringByAppendingString:ZXDescribePath(candidate)]];
    }

    // Listing the directory separately matters: if the candidates all report
    // MISSING but the directory itself cannot be read, the binaries are there
    // and this process is being denied, which is a different fix entirely.
    for (NSString *binDir in @[jbroot(@"/usr/bin"), @"/var/jb/usr/bin", @"/usr/bin"]) {
        NSError *dirError = nil;
        NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:binDir error:&dirError];
        if (entries) {
            NSMutableArray<NSString *> *pythons = [NSMutableArray array];
            for (NSString *entry in entries) {
                if ([entry hasPrefix:@"python"]) [pythons addObject:entry];
            }
            [lines addObject:[NSString stringWithFormat:@"  listing %@: %lu entries, python*: %@",
                              binDir, (unsigned long)entries.count,
                              pythons.count ? [pythons componentsJoinedByString:@", "] : @"none"]];
        } else {
            [lines addObject:[NSString stringWithFormat:@"  listing %@: FAILED (%@)",
                              binDir, dirError.localizedDescription ?: @"unknown error"]];
        }
    }

    return [lines componentsJoinedByString:@"\n"];
}



static NSString *ZXShellPath(void)
{
    return ZXFirstExecutablePath(@[
        jbroot(@"/bin/sh"),
        jbroot(@"/usr/bin/sh"),
        @"/var/jb/bin/sh",
        @"/var/jb/usr/bin/sh",
        @"/bin/sh",
        @"/usr/bin/sh"
    ]) ?: @"/bin/sh";
}

static NSString *ZXPythonModulePath(void)
{
    // The zxtouch module ships under /usr/share/zxtouch/python and the postinst
    // also copies it into every installed Python's site/dist-packages. Include
    // the share path unconditionally so scripts still find `import zxtouch`
    // even if the copy step skipped a Python version installed later.
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *path in @[
        jbroot(@"/usr/share/zxtouch/python"),
        jbroot(@"/usr/lib/python3/site-packages"),
        jbroot(@"/usr/lib/python3/dist-packages"),
        @"/var/jb/usr/share/zxtouch/python",
        @"/var/jb/usr/lib/python3/site-packages",
        @"/var/jb/usr/lib/python3/dist-packages",
        @"/usr/lib/python3/site-packages",
        @"/usr/lib/python3/dist-packages"
    ]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [paths addObject:path];
        }
    }
    return [paths componentsJoinedByString:@":"];
}

@implementation ScriptPlayer
{
    int repeatTime;
    float interval;
    float speed;
    NSString* scriptBundlePath;
    UIWindow *_playIndicator;
    int currentScriptType; // -1 no task has specified; 0 not playing but has upcoming task; 1 raw file playing; 2 py file playing
    NSTimer *replayTimer;
    UIView *circleView;
    Boolean scriptPlayForceStop;
    volatile sig_atomic_t scriptStopRequested;
    pid_t pythonProcessGroup;
    Boolean switchAppBeforePlaying;
    int _completedRuns;
}

- (BOOL)isPlaying {
    return isPlaying;
}

- (int)getCompletedRuns {
    return _completedRuns;
}

- (NSString*)getCurrentBundlePath {
    if (!scriptBundlePath)
    {
        return @"";
    }
    return scriptBundlePath;
}

- (void)setPath:(NSString*)path {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change script path because a script is playing.");
        return;
    }
    scriptBundlePath = path;
}

- (void)setRepeatTime:(int)rt {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change repeat time because a script is playing.");
        return;
    }
    repeatTime = rt;
}

- (void)setInterval:(float)intv {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change interval because a script is playing.");
        return;
    }
    interval = intv;
}

- (void)setSpeed:(float)sp {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change speed because a script is playing.");
        return;
    }
    speed = sp;
}

- (void)setSwitchApp:(BOOL)value {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change speed because a script is playing.");
        return;
    }
    switchAppBeforePlaying = value;
}


- (id)init {
    self = [super init];
    if (self)
    {
        [self clear];
        scriptStopRequested = 0;
        pythonProcessGroup = 0;
    }
    return self;
}

- (id)initWithPath:(NSString*)path {
    self = [super init];
    if (self)
    {
        scriptBundlePath = path;
        currentScriptType = -1;
        scriptStopRequested = 0;
        pythonProcessGroup = 0;
    }
    return self;
}

-(int)runScript:(NSError**)error {
    scriptStopRequested = 0;
    pythonProcessGroup = 0;

    if (!scriptBundlePath)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. ScriptBundlePath not set.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. ScriptBundlePath not set.\r\n"}];
        return -1;
    }

    BOOL isDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:scriptBundlePath isDirectory:&isDir] || !isDir)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Path not found or it is not a directory.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Path not found or it is not a directory.\r\n"}];
        return -1;
    }

    // read info.plist into dictionary
    NSString *infoFilePath = [NSString stringWithFormat:@"%@/info.plist", scriptBundlePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:infoFilePath isDirectory:&isDir])
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Info.plist not found.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Info.plist not found.\r\n"}];
        return -1;
    }
    NSDictionary *scriptInfo = [NSDictionary dictionaryWithContentsOfFile:infoFilePath];
    // get entry file extension
    NSString *entryFileName = scriptInfo[@"Entry"];
    NSString *fileExtension = [entryFileName pathExtension];

    NSString *foregroundApp = scriptInfo[@"FrontApp"];
    // call different functions depending on file extension

    // show indicator
    dispatch_async(dispatch_get_main_queue(), ^{
        // Attach to a UIWindowScene — a scene-less UIWindow is fatal from iOS 17
        // on. See the matching comment in Record.xm's startRecording.
        CGRect indicatorFrame = CGRectMake(0, 0, 10*2, 10*2);
        UIWindowScene *scene = (UIWindowScene *)[[UIApplication sharedApplication].connectedScenes anyObject];
        if (scene) {
            _playIndicator = [[UIWindow alloc] initWithWindowScene:scene];
            _playIndicator.frame = indicatorFrame;
        } else {
            _playIndicator = [[UIWindow alloc] initWithFrame:indicatorFrame];
        }
        UIViewController *indicatorRoot = [[UIViewController alloc] init];
        indicatorRoot.view.backgroundColor = [UIColor clearColor];
        _playIndicator.rootViewController = indicatorRoot;
        _playIndicator.windowLevel = UIWindowLevelStatusBar;
        [_playIndicator setBackgroundColor:[UIColor clearColor]];
        [_playIndicator setUserInteractionEnabled:NO];

        circleView = [[UIView alloc] initWithFrame:indicatorFrame];

        //circleView.alpha = 1;
        circleView.layer.cornerRadius = 10;  // half the width/height
        circleView.backgroundColor = [UIColor greenColor];
        [_playIndicator addSubview:circleView];

        _playIndicator.hidden = NO;
    });

    NSString *entryFilePath = [scriptBundlePath stringByAppendingPathComponent:entryFileName];
    NSLog(@"com.zjx.sprinboard: currently playing: %@. Repeat time: %d", entryFilePath, repeatTime);
    

    if ([fileExtension isEqualToString:@"raw"])
    {
        currentScriptType = 1;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            [self playFromRawFile:entryFilePath foregroundApp:foregroundApp err:&err];
        }); 
    }
    else if ([fileExtension isEqualToString:@"py"])
    {
        currentScriptType = 2;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            [self playFromPythonFile:entryFilePath foregroundApp:foregroundApp err:&err];
        });
        
    }
}

// play the script
- (int)play:(NSError**)error
{
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Another script is currently running.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Another script is currently running.\r\n"}];
        return -1;
    }
    _completedRuns = 0;
    [self runScript:error];
}


-(void)playFromRawFile:(NSString*) filePath foregroundApp:(NSString*)foregroundApp err:(NSError**)err
{
    isPlaying = true;
    if (switchAppBeforePlaying)
    {
        bringAppForeground(foregroundApp);
    }

    FILE *file = fopen([filePath UTF8String], "r");

    if (!file)
    {
        showAlertBox(@"Error", [NSString stringWithFormat:@"Cannot play this script because zxtouch cannot open the file. File path: %@", filePath], 999);
        isPlaying = false;
        return;
    }
    
    char buffer[256];
    
    BOOL stoppedByUser = NO;
    while (fgets(buffer, sizeof(char)*256, file) != NULL)
    {
        if (scriptPlayForceStop)
        {
            scriptPlayForceStop = false;
            stoppedByUser = YES;
            break;
        }
        int type;
        if (sscanf(buffer, "%2d", &type) != 1) {
            continue;
        }
        if (type == TASK_PERFORM_TOUCH) {
            performRecordedTouchFromRawData((const UInt8 *)buffer + 2);
        } else if (type == TASK_USLEEP && speed > 0 && speed != 1) {
            int sleepTime = (int)(atoi(buffer + 2) / speed);
            processTask((UInt8*)[[NSString stringWithFormat:@"18%d", sleepTime] UTF8String], NULL);
        } else {
            processTask((UInt8*)buffer, NULL);
        }
    }
    fclose(file);

    if (!stoppedByUser) [self playHasStopped];
}

-(void) playFromPythonFile:(NSString*) filePath foregroundApp:(NSString*) foregroundApp err:(NSError**) err
{
    isPlaying = true;

    if (switchAppBeforePlaying)
    {
        bringAppForeground(foregroundApp);
    }
    
    NSString *pythonPath = ZXPythonPath();
    if (!pythonPath)
    {
        NSString *diagnostics = ZXPythonDiagnostics();
        NSLog(@"com.zjx.springboard: %@", diagnostics);
        zxAppendRuntimeLog(diagnostics);

        showAlertBox(@"Python not installed",
                     @"ZXTouch could not find a working python3 on this device.\n\nIf python3 is installed from Sileo already, open Logs: the interpreter search is recorded there and shows which paths were checked and why each was rejected.",
                     999);
        isPlaying = false;
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
    {
        showAlertBox(@"Error", [NSString stringWithFormat:@"Cannot play this script. Script file not found in bdl folder. Script path: %@", filePath], 999);
        isPlaying = false;
        return;
    }
    // Ensure output log file exists so the >> redirect doesn't fail
    NSString *outputLog = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output";
    if (![[NSFileManager defaultManager] fileExistsAtPath:outputLog])
        [@"" writeToFile:outputLog atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *dateWrapper = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/add_datetime.sh";
    NSString *shellPath = ZXShellPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:dateWrapper]) {
        NSString *wrapper = [NSString stringWithFormat:@"#!%@\nOUTPUT=/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output\nDATE=/var/jb/usr/bin/date\nif [ ! -x \"$DATE\" ]; then DATE=/usr/bin/date; fi\nif [ ! -x \"$DATE\" ]; then DATE=/bin/date; fi\necho \"$($DATE '+%%m-%%d-%%Y %%T'): Start running script. Script path: $1\" >> \"$OUTPUT\"\nwhile IFS= read -r line; do\n    echo \"$($DATE '+%%m-%%d-%%Y %%T'): $line\" >> \"$OUTPUT\"\ndone\n", shellPath];
        [wrapper writeToFile:dateWrapper atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(dateWrapper.UTF8String, 0755);
    }

    NSString *scriptDir = [filePath stringByDeletingLastPathComponent];
    NSString *statusFile = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/last_python_status";
    NSString *pythonModulePath = ZXPythonModulePath();
    NSString *envPrefix = pythonModulePath.length > 0 ? [NSString stringWithFormat:@"PYTHONPATH=%@ ", ZXShellQuote(pythonModulePath)] : @"";
    NSString *commandToRun = [NSString stringWithFormat:@"rm -f %@; (cd %@ && %@%@ -u %@ 2>&1; echo $? > %@) | %@ %@ %@; exit $(cat %@ 2>/dev/null || echo 1)",
                              ZXShellQuote(statusFile),
                              ZXShellQuote(scriptDir),
                              envPrefix,
                              ZXShellQuote(pythonPath),
                              ZXShellQuote(filePath),
                              ZXShellQuote(statusFile),
                              ZXShellQuote(shellPath),
                              ZXShellQuote(dateWrapper),
                              ZXShellQuote(filePath),
                              ZXShellQuote(statusFile)];
    NSLog(@"com.zjx.springboard: command to run for running py file %@", commandToRun);

    int shellExitCode = system2Cancelable([commandToRun UTF8String], NULL, NULL,
                                          &pythonProcessGroup, &scriptStopRequested);
    BOOL stoppedByUser = scriptStopRequested != 0;
    scriptStopRequested = 0;
    NSString *statusText = [NSString stringWithContentsOfFile:statusFile encoding:NSUTF8StringEncoding error:nil];
    int pythonExitCode = statusText ? [statusText intValue] : shellExitCode;
    if (!stoppedByUser && pythonExitCode != 0) {
        NSString *title = @"Script Error";
        NSString *message;
        NSString *logTail = [NSString stringWithContentsOfFile:outputLog encoding:NSUTF8StringEncoding error:nil] ?: @"";
        BOOL dyldLibpythonMissing = [logTail rangeOfString:@"Library not loaded" options:0].location != NSNotFound &&
                                    [logTail rangeOfString:@"libpython" options:0].location != NSNotFound;
        if (statusText == nil && shellExitCode < 0) {
            // system2 failed before python could run — spawn was denied or the
            // shell was unusable. Common on semi-jailbreaks with stripped
            // entitlements. Check Console.app for `system2` NSLog output.
            title = @"Script could not launch";
            message = @"ZXTouch could not start a shell to run the script (posix_spawn failed).\n\nOpen Logs: the exact error and the shell path it tried are recorded there.";
        } else if (pythonExitCode == 134 && dyldLibpythonMissing) {
            // 134 = SIGABRT. Dyld couldn't find libpython — the interpreter
            // was linked against a path that doesn't exist on this JB (classic
            // Procursus python3.7 on rootless).
            title = @"Python interpreter is broken";
            message = @"The installed python3 aborted at launch because dyld cannot find its libpython dylib.\n\nInstall the 'python3' package (3.9 or newer) from Sileo (Procursus), then reinstall ZXTouch so it re-picks the working interpreter.";
        } else if (pythonExitCode == 125) {
            title = @"Script could not launch";
            message = @"ZXTouch started a process but the system refused to run a shell inside it.\n\nOpen Logs: the line beginning 'execve failed' gives the exact reason.";
        } else if (pythonExitCode == 127) {
            title = @"Python could not be run";
            message = @"The shell started but could not run python3.\n\nOpen Logs for the exact error. If python3 is not installed, install it from Sileo (Procursus).";
        } else {
            message = [NSString stringWithFormat:@"Python script exited with code %d. Open Logs for the traceback.", pythonExitCode];
        }
        NSLog(@"com.zjx.springboard: %@ — %@", title, message);
        showAlertBox(title, message, 999);
    }
    if (!stoppedByUser) [self playHasStopped];
}

- (void)replay:(NSTimer*)nstimer {
    NSLog(@"com.zjx.springboard: script is replaying...");
    NSError *err = nil;

    [self runScript:&err];

    CFRunLoopStop(CFRunLoopGetCurrent());
}

-(void) playHasStopped
{
    // If forceStop already called clear(), isPlaying is false — don't show finished popup
    if (!isPlaying) return;

    NSLog(@"com.zjx.springboard: script has finished");
    _completedRuns++;

    // check whether need to replay
    if (repeatTime != 0)
    {    
        dispatch_async(dispatch_get_main_queue(), ^{
            circleView.backgroundColor = [UIColor orangeColor];
        });

        NSLog(@"com.zjx.springboard: need replay. Replay time: %d", repeatTime);

        replayTimer = [NSTimer scheduledTimerWithTimeInterval:interval
         target:self selector:@selector(replay:) 
         userInfo:nil repeats:NO];
        repeatTime--;

        currentScriptType = 0;

        CFRunLoopRun();
    }
    else
    {
        playHasStoppedCallBack();
        [self clear];
    }



}

- (void)clear {
    repeatTime = 0;
    interval = 0.0f;
    speed = 1.0f;
    scriptBundlePath = nil;
    isPlaying = false;
    currentScriptType = -1;
    //scriptPlayForceStop = false;

    // remove indicator
    dispatch_async(dispatch_get_main_queue(), ^{
        _playIndicator.hidden = YES;
        _playIndicator = nil;
    });

    if (replayTimer)
        [replayTimer invalidate];

    replayTimer = nil;
}

- (void)forceStop:(NSError**)error {
    if (currentScriptType == -1)
    {
        NSLog(@"com.zjx.springboard: Cannot stop playing script. No script is playing.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Cannot stop script. No script is playing.\r\n"}];
        return;
    }

    if (currentScriptType == 0)
    {
        [self clear];
    }
    else if (currentScriptType == 1)
    {
        // make stop to be true
        scriptPlayForceStop = true;
        [self clear];
    }
    else if (currentScriptType == 2)
    {
        scriptStopRequested = 1;
        pid_t processGroup = pythonProcessGroup;
        if (processGroup > 0 && kill(-processGroup, SIGKILL) != 0 && errno != ESRCH) {
            NSLog(@"com.zjx.springboard: failed to stop Python process group %d: errno %d",
                  processGroup, errno);
        }
        [self clear];
    }
    else
    {
        NSLog(@"com.zjx.springboard: unknown currently playing script type.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Cannot stop script. Unkonwn currently playing script type.\r\n"}];
        return;
    }

}

@end
